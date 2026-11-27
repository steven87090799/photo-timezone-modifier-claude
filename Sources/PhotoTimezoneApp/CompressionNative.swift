import Foundation
import ImageIO
import TimezoneCore
import WebPBridge

/// Formats encoded directly with ImageIO or a native library.
enum CompressionNative {
    static func encode(source: URL, output: URL, format: CompressionFormat,
                       quality: Int, preview: Bool, cancellation: CancellationToken, orientation: Int = 1) throws -> CompressionJPEG.Result {
        if cancellation.isCancelled { throw CancellationError() }
        guard (1...100).contains(quality) else { throw PhotoError("品質必須介於 1～100。") }
        let raster: CompressionImages.Raster
        switch format {
        case .png:
            raster = try CompressionImages.encodeHighDepthPNG(source, output: output)
        case .webp:
            raster = try CompressionImages.raster(source, maxPixel: preview ? 900 : 0, preserveOriginal: true)
            let context = Unmanaged.passUnretained(cancellation).toOpaque()
            let encoded = raster.bytes.withUnsafeBytes { raw in
                output.withUnsafeFileSystemRepresentation { path in
                    photo_webp_encode(raw.bindMemory(to: UInt8.self).baseAddress, Int32(raster.width),
                                      Int32(raster.height), Int32(quality), preview ? 1 : 0, path,
                                      Int(CompressionImages.maximumFileBytes), { context in
                        guard let context else { return 1 }
                        return Unmanaged<CancellationToken>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                    }, context)
                }
            }
            if cancellation.isCancelled { throw CancellationError() }
            guard encoded == 1 else { throw PhotoError("WebP 編碼失敗；尺寸上限為 16,383 像素。") }
        case .heif, .avif:
            let heif = format == .heif
            if heif {
                raster = try CompressionImages.photoRaster(source, preview: preview, orientation: orientation)
            } else {
                raster = try CompressionImages.raster(source, maxPixel: preview ? 900 : 0, preserveOriginal: false)
            }
            let type = heif ? "public.heic" : "public.avif"
            guard let provider = CGDataProvider(data: raster.bytes as CFData),
                  let image = CGImage(width: raster.width, height: raster.height,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width * 4,
                    space: CompressionImages.colorSpace(source, preserveOriginal: raster.originalProfile),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
                throw PhotoError("macOS 無法建立 \(format.rawValue) 輸出。")
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: Double(quality) / 100,
                kCGImagePropertyOrientation: heif && !preview ? orientation : 1
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PhotoError("macOS \(format.rawValue) 編碼失敗。") }
        default:
            throw PhotoError("不支援的原生編碼格式。")
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard let encoded = CGImageSourceCreateWithURL(output as CFURL, nil),
              let header = try? CompressionImages.header(encoded),
              header.width == raster.width, header.height == raster.height,
              let image = CGImageSourceCreateImageAtIndex(encoded, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              format != .png || image.bitsPerComponent == raster.bitsPerComponent else {
            throw PhotoError("原生輸出未通過解碼、尺寸或像素精度驗證。")
        }
        return CompressionJPEG.Result(width: raster.width, height: raster.height,
            originalProfile: raster.originalProfile, frames: raster.frames)
    }
}
