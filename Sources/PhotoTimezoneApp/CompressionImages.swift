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
        let bitsPerComponent: Int
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

    static func sourceDepth(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return 8 }
        return image.bitsPerComponent
    }

    /// No resizing: comparison crops use the same coordinates on both images.
    static func comparisonCrop(_ url: URL, x: Double, y: Double, size: Int = 1024) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000,
              width <= 256 * 1024 * 1024 / 8 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let w = min(size, image.width), h = min(size, image.height)
        let left = Int((Double(image.width - w) * min(1, max(0, x))).rounded())
        let top = Int((Double(image.height - h) * min(1, max(0, y))).rounded())
        guard let crop = image.cropping(to: CGRect(x: left, y: top, width: w, height: h)) else { return nil }
        // CGImage.cropping can retain the entire decoded provider. Copy this
        // display-only ROI so closing the decode scope releases the full image.
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: crop.colorSpace?.model == .rgb ? crop.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let copied = context.makeImage() else { return nil }
        return NSImage(cgImage: copied, size: NSSize(width: w, height: h))
    }

    static func encodeHighDepthPNG(_ url: URL, output: URL) throws -> Raster {
        let raster = try raster(url, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        let space = colorSpace(url, preserveOriginal: raster.originalProfile)
        guard let provider = CGDataProvider(data: raster.bytes as CFData),
              let image = CGImage(width: raster.width, height: raster.height,
                bitsPerComponent: raster.bitsPerComponent, bitsPerPixel: raster.bitsPerComponent * 4,
                bytesPerRow: raster.width * raster.bitsPerComponent / 8 * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Compression", code: 5, userInfo: [NSLocalizedDescriptionKey: "無法建立 16 位元 PNG 輸出。"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Compression", code: 5, userInfo: [NSLocalizedDescriptionKey: "16 位元 PNG 編碼失敗。"] ) }
        return raster
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
    static func raster(_ url: URL, maxPixel: Int, preserveOriginal: Bool, preserveDepth: Bool = false) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000 else {
            throw NSError(domain: "Compression", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS 無法解碼這張影像，或尺寸超出上限。"])
        }
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        let depth = preserveDepth && (decoded?.bitsPerComponent ?? 8) > 8 ? 16 : 8
        if preserveDepth, let decoded, decoded.bitsPerComponent > 16 || decoded.bitmapInfo.contains(.floatComponents) {
            throw NSError(domain: "Compression", code: 4, userInfo: [NSLocalizedDescriptionKey: "此浮點或超過 16 位元來源無法保證無損，已停止輸出。請先轉為 8／16 位元整數影像。"])
        }
        if preserveDepth && maxPixel == 0, let decoded {
            return try integerRaster(decoded, orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1,
                                     frames: CGImageSourceGetCount(source))
        }
        let sampleBytes = depth / 8
        let limit = maxPixel > 0 ? maxPixel : max(width, height)
        guard maxPixel > 0 || width <= 256 * 1024 * 1024 / (4 * sampleBytes) / height else {
            throw NSError(domain: "Compression", code: 2, userInfo: [NSLocalizedDescriptionKey: "解碼後像素超過 256 MiB；請先縮小影像。"])
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), image.width <= 256 * 1024 * 1024 / (4 * sampleBytes) / image.height else {
            throw NSError(domain: "Compression", code: 2, userInfo: [NSLocalizedDescriptionKey: "解碼後像素超過 256 MiB；請先縮小影像。"])
        }
        let original = preserveOriginal && image.colorSpace?.model == .rgb
        let space = original ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let count = image.width * image.height * 4 * sampleBytes
        var pixels = Data(count: count)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: depth, bytesPerRow: image.width * 4 * sampleBytes, space: space,
                bitmapInfo: (depth == 16 ? CGBitmapInfo.byteOrder16Little : CGBitmapInfo.byteOrder32Big).rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // WASM encoders consume straight alpha, while CoreGraphics draws premultiplied alpha.
            if depth == 16 {
                let words = raw.bindMemory(to: UInt16.self)
                for index in stride(from: 0, to: words.count, by: 4) {
                    if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { words[index + 3] = 65535 }
                    let alpha = UInt64(words[index + 3])
                    if alpha > 0 && alpha < 65535 {
                        for channel in 0..<3 { words[index + channel] = UInt16(min(65535, (UInt64(words[index + channel]) * 65535 + alpha / 2) / alpha)) }
                    }
                }
                return true
            }
            let bytes = raw.bindMemory(to: UInt8.self)
            if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) {
                for index in stride(from: 0, to: count, by: 4) { bytes[index + 3] = 255 }
            } else {
                for index in stride(from: 0, to: count, by: 4) {
                    let alpha = Int(bytes[index + 3])
                    if alpha > 0 && alpha < 255 {
                        for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha)) }
                    }
                }
            }
            return true
        }
        guard ok else { throw NSError(domain: "Compression", code: 3, userInfo: [NSLocalizedDescriptionKey: "無法建立影像像素緩衝區。"]) }
        return Raster(bytes: pixels, width: image.width, height: image.height,
            originalProfile: original, frames: CGImageSourceGetCount(source), bitsPerComponent: depth)
    }
    /// Copy integer RGB samples directly, without a premultiply/unpremultiply
    /// rendering round trip. Orientation is an integer permutation of pixels.
    private static func integerRaster(_ image: CGImage, orientation: Int, frames: Int) throws -> Raster {
        let bits = image.bitsPerComponent, bytes = bits / 8
        let components = image.bitsPerPixel / bits
        guard [8, 16].contains(bits), [3, 4].contains(components),
              image.colorSpace?.model == .rgb, !image.bitmapInfo.contains(.floatComponents),
              let input = image.dataProvider?.data as Data?,
              image.width <= 256 * 1024 * 1024 / (4 * bytes) / image.height,
              input.count >= image.bytesPerRow * image.height,
              (1...8).contains(orientation) else {
            throw NSError(domain: "Compression", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "此來源的像素／色彩排列無法保證逐像素無損，已停止輸出。請先轉為標準 8／16 位元 RGB 影像。"])
        }
        let alpha = image.alphaInfo
        guard [.none, .noneSkipFirst, .noneSkipLast, .first, .last].contains(alpha) else {
            throw NSError(domain: "Compression", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "來源使用預乘透明通道，無法保證逐像素無損，已停止輸出。請先轉為標準 RGB／RGBA 影像。"])
        }
        let width = orientation >= 5 ? image.height : image.width
        let height = orientation >= 5 ? image.width : image.height
        var output = Data(count: width * height * 4 * bytes)
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let reverse8 = bits == 8 && components == 4 && order == .byteOrder32Little
        let little16 = bits == 16 && order == .byteOrder16Little
        let first = [.first, .noneSkipFirst].contains(alpha)
        let hasAlpha = [.first, .last].contains(alpha)
        let maximum = bits == 16 ? 65535 : 255
        input.withUnsafeBytes { source in
            let raw = source.bindMemory(to: UInt8.self)
            output.withUnsafeMutableBytes { target in
                let dest = target.bindMemory(to: UInt8.self)
                func sample(_ offset: Int, _ component: Int) -> Int {
                    let index = offset + (reverse8 ? components - 1 - component : component) * bytes
                    if bits == 8 { return Int(raw[index]) }
                    return little16 ? Int(raw[index]) | Int(raw[index + 1]) << 8 : Int(raw[index]) << 8 | Int(raw[index + 1])
                }
                for y in 0..<image.height { for x in 0..<image.width {
                    let offset = y * image.bytesPerRow + x * components * bytes
                    let point: (Int, Int)
                    switch orientation {
                    case 2: point = (image.width - 1 - x, y)
                    case 3: point = (image.width - 1 - x, image.height - 1 - y)
                    case 4: point = (x, image.height - 1 - y)
                    case 5: point = (y, x)
                    case 6: point = (image.height - 1 - y, x)
                    case 7: point = (image.height - 1 - y, image.width - 1 - x)
                    case 8: point = (y, image.width - 1 - x)
                    default: point = (x, y)
                    }
                    let index = (point.1 * width + point.0) * 4 * bytes
                    for channel in 0..<4 {
                        let value = channel == 3 ? (hasAlpha ? sample(offset, first ? 0 : 3) : maximum) : sample(offset, channel + (first ? 1 : 0))
                        dest[index + channel * bytes] = UInt8(truncatingIfNeeded: value)
                        if bits == 16 { dest[index + channel * bytes + 1] = UInt8(truncatingIfNeeded: value >> 8) }
                    }
                }}
            }
        }
        return Raster(bytes: output, width: width, height: height, originalProfile: true, frames: frames, bitsPerComponent: bits)
    }

}
