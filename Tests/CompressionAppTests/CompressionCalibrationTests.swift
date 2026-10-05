import AppKit
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import PhotoTimezoneApp
@testable import TimezoneCore

/// Opt-in: writes only to a fresh output folder; source photos are hash checked.
@Suite(.serialized)
@MainActor
struct CompressionCalibrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_COMPRESSION_CALIBRATION_SOURCE"] != nil))
    func actualPhotosCalibrateJPEGAndNativeHEIF() async throws {
        let env = ProcessInfo.processInfo.environment
        let sourceRoot = URL(fileURLWithPath: try #require(env["PHOTO_COMPRESSION_CALIBRATION_SOURCE"]))
        let outputRoot = URL(fileURLWithPath: try #require(env["PHOTO_COMPRESSION_CALIBRATION_OUTPUT"]))
        guard !FileManager.default.fileExists(atPath: outputRoot.path) else { throw PhotoError("校準輸出資料夾已存在；拒絕覆寫。") }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCalibration-\(UUID())")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let sources = try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!sources.isEmpty)
        let toolURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/vendor-exiftool/exiftool")
        let tool = ExifTool(url: toolURL)
        let host = CompressionHost(); defer { host.shutdown() }
        var hashes: [String: String] = [:]
        func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined() }
        for source in sources {
            hashes[source.lastPathComponent] = try digest(source)
            try FileManager.default.copyItem(at: source, to: local.appendingPathComponent(source.lastPathComponent))
        }
        let curve = env["PHOTO_COMPRESSION_CALIBRATION_MODE"] != "batch"
        let indexes = Set((0..<min(9, sources.count)).map { $0 * (sources.count - 1) / max(1, min(9, sources.count) - 1) })
        let candidates = curve ? sources.enumerated().filter { indexes.contains($0.offset) }.map(\.element) : sources
        let jpegQualities = curve ? (env["PHOTO_COMPRESSION_CALIBRATION_JPEG_QUALITIES"]?.split(separator: ",").compactMap { Int($0) } ?? [78, 82, 86, 90, 94, 96]) : [Int(env["PHOTO_COMPRESSION_CALIBRATION_JPEG_QUALITY"] ?? "90")!]
        let heifQualities = curve ? (env["PHOTO_COMPRESSION_CALIBRATION_HEIF_QUALITIES"]?.split(separator: ",").compactMap { Int($0) } ?? [60, 70, 80, 86, 90, 94]) : [Int(env["PHOTO_COMPRESSION_CALIBRATION_HEIF_QUALITY"] ?? "80")!]
        var rows: [[String: Any]] = []
        func persist() throws {
            let report: [String: Any] = ["sourceCount": sources.count, "testedCount": candidates.count, "mode": curve ? "curve" : "batch",
                "metric": "SSIMULACRA2 on three original-resolution 1024px crops; no resized-image comparison",
                "cropPositions": [[0.15, 0.15], [0.5, 0.5], [0.85, 0.85]], "rows": rows,
                "sourceSHA256": hashes]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputRoot.appendingPathComponent("results.json"), options: .atomic)
        }
        for original in candidates {
            let source = local.appendingPathComponent(original.lastPathComponent)
            let sourceBytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
            let before = try tool.snapshot(source, strictOffsets: false, forCompression: true)
            let icc = try tool.execute(["-b", "-ICC_Profile", source.path]).stdout
            let referenceCrops = try makeCrops(source, in: local, prefix: "reference")
            for format in [CompressionFormat.jpeg, .heif] {
                for quality in format == .jpeg ? jpegQualities : heifQualities {
                    let started = Date()
                    let result = try await host.perform(source: source, format: format, quality: quality, preview: false)
                    let folder = outputRoot.appendingPathComponent("\(format.fileExtension)-q\(quality)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let saved = folder.appendingPathComponent(original.deletingPathExtension().lastPathComponent + "." + format.fileExtension)
                    try CompressionExports.saveFile(result.url, to: saved)
                    let actual = Int64(try saved.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
                    #expect(actual == result.bytes && result.sourceBytes == sourceBytes)
                    let encoded = try #require(CGImageSourceCreateWithURL(saved as CFURL, nil))
                    #expect(CGImageSourceGetType(encoded) as String? == (format == .jpeg ? "public.jpeg" : "public.heic"))
                    let after = try tool.snapshot(saved, strictOffsets: false, forCompression: true)
                    #expect(after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal)
                    #expect(after.metadata.offsetOriginal == before.metadata.offsetOriginal)
                    #expect(after.metadata.gpsLatitude == before.metadata.gpsLatitude)
                    #expect(after.metadata.gpsLongitude == before.metadata.gpsLongitude)
                    #expect(try tool.execute(["-b", "-ICC_Profile", saved.path]).stdout == icc)
                    let outputCrops = try makeCrops(saved, in: local, prefix: "output")
                    var scores: [Double] = []
                    for i in referenceCrops.indices { scores.append(try score(referenceCrops[i], outputCrops[i])) }
                    rows.append(["source": original.lastPathComponent, "format": format.rawValue, "quality": quality,
                        "sourceBytes": sourceBytes, "outputBytes": actual, "savingsPercent": (1 - Double(actual) / Double(sourceBytes)) * 100,
                        "ratio": Double(sourceBytes) / Double(actual), "scores": scores,
                        "metadataStatus": result.metadataStatus, "chroma": String(decoding: try tool.execute(["-s3", "-YCbCrSubSampling", saved.path]).stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "seconds": Date().timeIntervalSince(started),
                        "sizeVerified": true, "dateTimezoneGPSICCVerified": true, "output": saved.path])
                    try persist()
                    print("CALIBRATION \(original.lastPathComponent) \(format.rawValue) q\(quality): \(actual) bytes; scores \(scores)")
                    try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
                }
            }
        }
        for source in sources { #expect(try digest(source) == hashes[source.lastPathComponent], "Original source was changed") }
        #expect(host.webView == nil, "JPEG and HEIF must use native encoders only")
        try persist()
    }

    private func makeCrops(_ url: URL, in folder: URL, prefix: String) throws -> [URL] {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height)
                  ] as CFDictionary) else { throw PhotoError("無法解碼校準影像。") }
            var files: [URL] = []
            for (i, fraction) in [0.15, 0.5, 0.85].enumerated() {
                let w = min(1024, image.width), h = min(1024, image.height)
                let crop = try #require(image.cropping(to: CGRect(x: Int(Double(image.width - w) * fraction),
                    y: Int(Double(image.height - h) * fraction), width: w, height: h)))
                let file = folder.appendingPathComponent("\(prefix)-\(i).png")
                let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, crop, nil); #expect(CGImageDestinationFinalize(destination))
                files.append(file)
            }
            return files
        }
    }

    private func score(_ reference: URL, _ output: URL) throws -> Double {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ssimulacra2")
        process.arguments = [reference.path, output.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let score = Double(text), score.isFinite else { throw PhotoError("SSIMULACRA2 量測失敗。") }
        return score
    }
}
