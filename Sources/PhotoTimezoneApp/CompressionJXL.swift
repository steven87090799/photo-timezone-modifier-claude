import Foundation
import ImageIO
import JXLBridge
import TimezoneCore

enum CompressionJXL {
    struct Result {
        let width: Int
        let height: Int
        let originalProfile: Bool
        let frames: Int
    }

    static func encode(source: URL, output: URL, quality: Int,
                       preview: Bool, cancellation: CancellationToken) throws -> Result {
        try autoreleasepool {
            guard (1...100).contains(quality) else { throw PhotoError("JPEG XL 品質必須介於 1～100。") }
            if cancellation.isCancelled { throw CancellationError() }
            let maximumPixel = preview ? 900 : 0
            var raster = try CompressionImages.raster(source, maxPixel: maximumPixel,
                                                       preserveOriginal: true)
            let icc = raster.originalProfile
                ? CompressionImages.colorSpace(source, preserveOriginal: true).copyICCData() as Data?
                : nil
            // Do not label sRGB samples with a source profile when ImageIO
            // cannot provide that profile's ICC payload.
            if raster.originalProfile && icc == nil {
                raster = try CompressionImages.raster(source, maxPixel: preview ? 900 : 0,
                                                       preserveOriginal: false)
            }
            let iccProfile = icc ?? Data()
            if cancellation.isCancelled { throw CancellationError() }
            let pixels = raster.width * raster.height
            let effort = pixels > 20_000_000 ? 1 : pixels > 12_000_000 ? 3 : 5
            var encoded: UnsafeMutablePointer<UInt8>?
            var count = 0
            var message = [CChar](repeating: 0, count: 512)
            let result = raster.bytes.withUnsafeBytes { bytes in
                iccProfile.withUnsafeBytes { profile in
                    pt_jxl_encode_rgba(bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count, UInt32(raster.width), UInt32(raster.height),
                        Int32(quality), Int32(effort),
                        profile.bindMemory(to: UInt8.self).baseAddress, profile.count,
                        jxlCancelled, Unmanaged.passUnretained(cancellation).toOpaque(),
                        &encoded, &count, &message, message.count)
                }
            }
            defer { pt_jxl_free(encoded) }
            if result == 2 || cancellation.isCancelled { throw CancellationError() }
            guard result == 0, let encoded, count > 0 else {
                throw PhotoError("JPEG XL 編碼失敗：\(String(cString: message))")
            }
            let data = Data(bytes: encoded, count: count)
            let signature = Data([0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20])
            guard data.starts(with: signature) else {
                throw PhotoError("JPEG XL 輸出容器無效；已停止這張照片的輸出。")
            }
            try data.write(to: output, options: .atomic)
            if cancellation.isCancelled { throw CancellationError() }
            return Result(width: raster.width, height: raster.height,
                          originalProfile: raster.originalProfile && !iccProfile.isEmpty,
                          frames: raster.frames)
        }
    }

    static func profileMatches(_ url: URL, expected: Data) -> Bool {
        guard let encoded = try? Data(contentsOf: url, options: .mappedIfSafe),
              !encoded.isEmpty, !expected.isEmpty else { return false }
        return encoded.withUnsafeBytes { jxl in
            expected.withUnsafeBytes { profile in
                pt_jxl_profile_matches(jxl.bindMemory(to: UInt8.self).baseAddress,
                    jxl.count, profile.bindMemory(to: UInt8.self).baseAddress,
                    profile.count, 0.001) == 1
            }
        }
    }
}

private func jxlCancelled(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 1 }
    return Unmanaged<CancellationToken>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
}
