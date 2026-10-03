import AppKit
import Foundation
import ImageIO

enum CompressionImages {
    struct Raster {
        let bytes: Data
        let width: Int
        let height: Int
        let originalProfile: Bool
        let frames: Int
    }

    static func thumbnail(_ url: URL, size: Int = 1200, profile: CGColorSpace? = nil) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let display = profile.flatMap { image.copy(colorSpace: $0) } ?? image
        return NSImage(cgImage: display, size: NSSize(width: display.width, height: display.height))
    }

    static func colorSpace(_ url: URL, preserveOriginal: Bool) -> CGColorSpace {
        if preserveOriginal, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
           let space = image.colorSpace, space.model == .rgb {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Decode with ImageIO and keep RGB samples in the output's declared profile.
    /// WebKit canvas color conversion is deliberately bypassed for full outputs.
    static func raster(_ url: URL, maxPixel: Int, preserveOriginal: Bool) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000 else {
            throw NSError(domain: "Compression", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS 無法解碼這張影像，或尺寸超出上限。"])
        }
        let limit = maxPixel > 0 ? maxPixel : max(width, height)
        guard maxPixel > 0 || width <= 256 * 1024 * 1024 / 4 / height else {
            throw NSError(domain: "Compression", code: 2, userInfo: [NSLocalizedDescriptionKey: "解碼後像素超過 256 MiB；請先縮小影像。"])
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), image.width <= 256 * 1024 * 1024 / 4 / image.height else {
            throw NSError(domain: "Compression", code: 2, userInfo: [NSLocalizedDescriptionKey: "解碼後像素超過 256 MiB；請先縮小影像。"])
        }
        let original = preserveOriginal && image.colorSpace?.model == .rgb
        let space = original ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let count = image.width * image.height * 4
        var pixels = Data(count: count)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // WASM encoders consume straight alpha, while CoreGraphics draws premultiplied alpha.
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: count, by: 4) {
                let alpha = Int(bytes[index + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha)) }
                }
            }
            return true
        }
        guard ok else { throw NSError(domain: "Compression", code: 3, userInfo: [NSLocalizedDescriptionKey: "無法建立影像像素緩衝區。"]) }
        return Raster(bytes: pixels, width: image.width, height: image.height,
            originalProfile: original, frames: CGImageSourceGetCount(source))
    }
}
