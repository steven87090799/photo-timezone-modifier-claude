import Foundation
import ImageIO
import TimezoneCore

/// HEIF never creates a WebKit worker or invokes a third party converter.
enum CompressionNative {
    static func encode(source: URL, output: URL, format: CompressionFormat,
                       quality: Int, preview: Bool, cancellation: CancellationToken) throws -> CompressionJPEG.Result {
        if cancellation.isCancelled { throw CancellationError() }
        guard (1...100).contains(quality) else { throw PhotoError("品質必須介於 1～100。") }
        let raster: CompressionImages.Raster
        if format == .png {
            raster = try CompressionImages.encodeHighDepthPNG(source, output: output)
        } else {
            raster = try CompressionImages.raster(source, maxPixel: preview ? 900 : 0, preserveOriginal: true)
            guard let provider = CGDataProvider(data: raster.bytes as CFData),
                  let image = CGImage(width: raster.width, height: raster.height,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width * 4,
                    space: CompressionImages.colorSpace(source, preserveOriginal: raster.originalProfile),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.heic" as CFString, 1, nil) else {
                throw PhotoError("macOS 無法建立 HEIF 輸出。")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PhotoError("macOS HEIF 編碼失敗。") }
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard let encoded = CGImageSourceCreateWithURL(output as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(encoded, 0, nil),
              image.width == raster.width, image.height == raster.height,
              format != .png || image.bitsPerComponent == raster.bitsPerComponent else {
            throw PhotoError("原生輸出未通過解碼、尺寸或像素精度驗證。")
        }
        return CompressionJPEG.Result(width: raster.width, height: raster.height,
            originalProfile: raster.originalProfile, frames: raster.frames)
    }
}
