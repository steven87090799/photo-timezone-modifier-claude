import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import TimezoneCore

enum RAWDecoder: String, CaseIterable, Identifiable, Sendable {
    case version9 = "Apple RAW 9"
    case version8 = "Apple RAW 8"
    var id: String { rawValue }

    func supportedVersion(in versions: [CIRAWDecoderVersion]) throws -> CIRAWDecoderVersion {
        let candidates: [CIRAWDecoderVersion] = self == .version9 ? [.version9, .version9DNG] : [.version8, .version8DNG]
        guard let version = candidates.first(where: versions.contains) else {
            throw PhotoError("這張 RAW 不支援 \(rawValue)，請選擇其他顯影版本；不會自動改用其他版本。")
        }
        return version
    }
}

/// RAW development produces a disposable, oriented sRGB TIFF. Existing codecs
/// consume that image; the sensor data and camera-specific blocks stay in RAW.
enum CompressionRAW {
    static let extensions = RAWMetadataTransfer.extensions
    private static let renderGate = DispatchSemaphore(value: 1)

    static func isRAW(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { return false }
        return UTType(type)?.conforms(to: .rawImage) == true
    }

    static func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return extensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .rawImage) == true
    }

    @discardableResult
    static func develop(source: URL, output: URL, decoder: RAWDecoder, sixteenBit: Bool,
                        cancellation: CancellationToken, maxPixel: Int = 0,
                        orientation: Int? = nil) throws -> (width: Int, height: Int) {
        try autoreleasepool {
            if cancellation.isCancelled { throw CancellationError() }
            // Switching previews can cancel a task while Core Image is still
            // rendering. Wait before starting another expensive RAW render.
            while renderGate.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                if cancellation.isCancelled { throw CancellationError() }
            }
            defer { renderGate.signal() }
            if cancellation.isCancelled { throw CancellationError() }
            guard isRAW(source), let filter = CIRAWFilter(imageURL: source) else {
                throw PhotoError("Apple 顯影器無法讀取這張 RAW；相機型號或 RAW 壓縮模式可能尚未支援。")
            }
            filter.decoderVersion = try decoder.supportedVersion(in: filter.supportedDecoderVersions)
            if let orientation {
                guard let value = CGImagePropertyOrientation(rawValue: UInt32(exactly: orientation) ?? 0) else {
                    throw PhotoError("RAW 主要影像方向無效。")
                }
                filter.orientation = value
            }
            let size = filter.nativeSize
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width <= 20000, size.height <= 20000 else { throw PhotoError("RAW 尺寸無效或超出上限。") }
            filter.scaleFactor = maxPixel > 0 ? Float(min(1, Double(maxPixel) / max(size.width, size.height))) : 1
            let state = ResourceDownload()
            let download = filter.downloadResources(timeout: 60) { error in state.finish(error) }
            let deadline = ProcessInfo.processInfo.systemUptime + 65
            while state.ready.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                if cancellation.isCancelled { download.cancel(); throw CancellationError() }
                if ProcessInfo.processInfo.systemUptime > deadline {
                    download.cancel(); throw PhotoError("Apple RAW 顯影資源準備逾時，請稍後重試。")
                }
            }
            if let error = state.error { throw PhotoError("\(decoder.rawValue) 顯影資源無法準備：\(error.localizedDescription)") }
            if cancellation.isCancelled { throw CancellationError() }
            // CIRAWFilter applies its explicitly chosen orientation to pixels.
            // Remove the original properties so it cannot be applied twice.
            guard let image = filter.outputImage?.settingProperties([:]) else {
                throw PhotoError("\(decoder.rawValue) 無法產生顯影影像。")
            }
            let rect = image.extent
            let sampleBytes = sixteenBit ? 8.0 : 4.0
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
                  rect.width * rect.height * sampleBytes <= 256 * 1024 * 1024 else {
                throw PhotoError("RAW 顯影後像素超過 256 MiB；請選擇 8 位元輸出，或先由修圖軟體縮小影像。")
            }
            let context = CIContext(options: [.cacheIntermediates: false])
            try context.writeTIFFRepresentation(of: image, to: output, format: sixteenBit ? .RGBX16 : .RGBX8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
            if cancellation.isCancelled { throw CancellationError() }
            guard let check = CGImageSourceCreateWithURL(output as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == Int(rect.width),
                  properties[kCGImagePropertyPixelHeight] as? Int == Int(rect.height) else {
                throw PhotoError("RAW 顯影影像未通過尺寸驗證。")
            }
            return (Int(rect.width), Int(rect.height))
        }
    }

    private final class ResourceDownload: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var failure: Error?
        var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
        func finish(_ error: Error?) { lock.lock(); failure = error; lock.unlock(); ready.signal() }
    }
}
