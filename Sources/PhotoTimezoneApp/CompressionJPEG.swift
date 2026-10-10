import Foundation
import ImageIO
import JpegliBridge
import TimezoneCore

enum CompressionJPEG {
    struct Result {
        let width: Int
        let height: Int
        let originalProfile: Bool
        let frames: Int
    }

    /// No WebKit, HTTP transfer or WASM heap for JPEG. Each encode owns its
    /// buffers and releases them before the metadata pass begins.
    static func encode(source: URL, output: URL, quality: Int, preview: Bool,
                       cancellation: CancellationToken, orientation: Int = 1) throws -> Result {
        try autoreleasepool {
            guard (1...100).contains(quality) else { throw PhotoError("JPEG 品質必須介於 1～100。") }
            if cancellation.isCancelled { throw CancellationError() }
            let raster = try CompressionImages.photoRaster(source, preview: preview, orientation: orientation)
            if cancellation.isCancelled { throw CancellationError() }
            var encoded: UnsafeMutablePointer<UInt8>?
            var count = 0
            var message = [CChar](repeating: 0, count: 512)
            let status = raster.bytes.withUnsafeBytes { bytes in
                pt_jpegli_encode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                    Int32(raster.width), Int32(raster.height), Int32(quality), { context in
                        guard let context else { return 1 }
                        return Unmanaged<CancellationToken>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                    }, Unmanaged.passUnretained(cancellation).toOpaque(), &encoded, &count, &message, message.count)
            }
            defer { pt_jpegli_free(encoded) }
            if status == 2 || cancellation.isCancelled { throw CancellationError() }
            guard status == 0, let encoded, count > 0 else {
                throw PhotoError("Jpegli 編碼失敗：\(String(cString: message))")
            }
            try Data(bytesNoCopy: encoded, count: count, deallocator: .none).write(to: output, options: .atomic)
            // Verify with the platform decoder as well as JPEG's SOI/EOI markers.
            guard let check = CGImageSourceCreateWithURL(output as CFURL, nil),
                  CGImageSourceGetType(check) as String? == "public.jpeg",
                  let image = CGImageSourceCreateImageAtIndex(check, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width == raster.width, image.height == raster.height,
                  CGImageSourceGetStatus(check) == .statusComplete else {
                throw PhotoError("Jpegli 輸出不是可正常解碼的標準 JPEG，已停止這張照片的輸出。")
            }
            if cancellation.isCancelled { throw CancellationError() }
            return Result(width: raster.width, height: raster.height,
                          originalProfile: raster.originalProfile, frames: raster.frames)
        }
    }
}
