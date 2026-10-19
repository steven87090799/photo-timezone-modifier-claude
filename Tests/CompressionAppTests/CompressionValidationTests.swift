import AppKit
import Foundation
import ImageIO
import Testing
import TimezoneCore
@testable import PhotoTimezoneApp

@Suite(.serialized)
@MainActor
struct CompressionValidationTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveValidation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func image(bits: Int = 8) throws -> CGImage {
        let bytes = bits / 8
        let samples = Data(repeating: 0xFF, count: 8 * 4 * 4 * bytes)
        let provider = try #require(CGDataProvider(data: samples as CFData))
        return try #require(CGImage(width: 8, height: 4, bitsPerComponent: bits, bitsPerPixel: 4 * bits,
            bytesPerRow: 8 * 4 * bytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                .union(bits == 16 ? .byteOrder16Little : .byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func fixture(_ file: URL, type: String = "public.png", bits: Int = 8, frames: Int = 1) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, type as CFString, frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(destination, try image(bits: bits), nil) }
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func sixteenBitSourceCannotBeSilentlyReducedToEightBits() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("high-depth.png")
        try fixture(source, bits: 16)
        let original = try Data(contentsOf: source)
        #expect(try CompressionValidation.sourceDepth(source, format: .png, quality: 82) == 16)
        #expect(try CompressionValidation.sourceDepth(source, format: .jxl, quality: 100) == 16)
        for format in [CompressionFormat.jpeg, .heif, .webp, .avif, .jxl] {
            #expect(throws: PhotoError.self) {
                _ = try CompressionValidation.sourceDepth(source, format: format, quality: 82)
            }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func animationFailsBeforeAnyOutputCanBeAccepted() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("two-frames.gif")
        try fixture(source, type: "com.compuserve.gif", frames: 2)
        let original = try Data(contentsOf: source)
        let host = CompressionHost(); defer { host.shutdown() }
        do {
            _ = try await host.perform(source: source, format: .jpeg, quality: 86, preview: false)
            Issue.record("A two-frame source must not be accepted as a single-frame archive")
        } catch let error as PhotoError {
            #expect(error.localizedDescription.contains("多頁") || error.localizedDescription.contains("影格"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.workDirectory.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func externalMetadataFilesCannotDisappearDuringCompression() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.png")
        try fixture(source)
        let original = try Data(contentsOf: source)
        try CompressionPhotoReader.requireEmbeddedMetadataOnly(source)
        for name in ["photo.XmP", "photo.png.xmp", "photo.on1", "photo.acr"] {
            let sidecar = root.appendingPathComponent(name)
            let sidecarBytes = Data("External edits and metadata must stay associated".utf8)
            try sidecarBytes.write(to: sidecar)
            #expect(throws: PhotoError.self) { try CompressionPhotoReader.requireEmbeddedMetadataOnly(source) }
            let host = CompressionHost()
            do {
                _ = try await host.perform(source: source, format: .jpeg, quality: 86, preview: false)
                Issue.record("Source with \(name) must not silently lose external metadata")
            } catch let error as PhotoError {
                #expect(error.localizedDescription.contains("伴隨檔"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: host.workDirectory.path).isEmpty)
            host.shutdown()
            #expect(try Data(contentsOf: sidecar) == sidecarBytes)
            try FileManager.default.removeItem(at: sidecar)
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func finalContainerMustFullyDecodeAtTheDeclaredDimensions() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("output.png")
        try fixture(file)
        try CompressionValidation.verifyOutput(file, width: 8, height: 4)
        #expect(throws: PhotoError.self) { try CompressionValidation.verifyOutput(file, width: 4, height: 8) }
        let complete = try Data(contentsOf: file)
        try complete.prefix(complete.count / 2).write(to: file)
        #expect(throws: PhotoError.self) { try CompressionValidation.verifyOutput(file, width: 8, height: 4) }
    }

    @Test func opaqueHEIFUUIDMetadataCannotDisappearIntoJPEG() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("private-metadata.heic")
        try fixture(source, type: "public.heic")
        let payload = Data(0..<16) + Data("private archival metadata".utf8)
        let size = UInt32(payload.count + 8)
        let block = Data([UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                          UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)]) + Data("uuid".utf8) + payload
        let original = try Data(contentsOf: source) + block
        try original.write(to: source)
        let host = CompressionHost(); defer { host.shutdown() }
        do {
            _ = try await host.perform(source: source, format: .jpeg, quality: 86, preview: false)
            Issue.record("An opaque HEIF UUID block must not disappear in a successful conversion")
        } catch {
            #expect(error.localizedDescription.contains("UUID"), "\(error)")
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.workDirectory.path).isEmpty)
    }

    @Test func losslessGateDetectsChangedPixelsEvenWhenContainerAndDimensionsAreValid() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let output = root.appendingPathComponent("output.png")
        try fixture(source)
        try FileManager.default.copyItem(at: source, to: output)
        try CompressionValidation.verifyLosslessOutput(source: source, output: output)
        let black = Data(repeating: 0, count: 8 * 4 * 3)
        let provider = try #require(CGDataProvider(data: black as CFData))
        let altered = try #require(CGImage(width: 8, height: 4, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: 8 * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, altered, nil)
        #expect(CGImageDestinationFinalize(destination))
        try CompressionValidation.verifyOutput(output, width: 8, height: 4)
        #expect(throws: PhotoError.self) {
            try CompressionValidation.verifyLosslessOutput(source: source, output: output)
        }
    }
}
