import Foundation
import Testing
@testable import TimezoneCore

@Suite(.serialized)
final class ImagePayloadVerifierTests: TemporaryDirectoryTestCase {
    private let tool: ExifTool

    override init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = ProcessInfo.processInfo.environment["TEST_EXIFTOOL_PATH"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent(".build/vendor-exiftool/exiftool")
        tool = ExifTool(url: url, persistent: true)
        try super.init()
    }

    @Test func JPEGMetadataChangePreservesEveryEncodedImageByte() throws {
        let source = try makePhoto("source.jpg")
        let candidate = temporaryDirectory.appendingPathComponent("candidate.jpg")
        try FileManager.default.copyItem(at: source, to: candidate)
        let before = try tool.snapshot(source)
        #expect(try tool.execute(["-overwrite_original", "-OffsetTimeOriginal=+08:00", candidate.path]).status == 0)
        let after = try tool.snapshot(candidate)
        try ImagePayloadVerifier.verify(source: source, candidate: candidate, before: before, after: after, tool: tool)
    }

    @Test func JPEGEntropyMutationIsRejectedEvenWithIdenticalMetadata() throws {
        let source = try makePhoto("source.jpg")
        let candidate = temporaryDirectory.appendingPathComponent("changed.jpg")
        var bytes = try Data(contentsOf: source)
        let scan = try requireValue(JPEGPayloadLayout.retainedRanges(in: source).last)
        let start = Int(scan.start)
        // Locate SOS inside the retained final range, then alter one entropy
        // byte without touching any marker, table, EXIF or image dimensions.
        let sos = try requireValue((start..<bytes.count - 3).first { bytes[$0] == 0xff && bytes[$0 + 1] == 0xda })
        let entropy = sos + 2 + Int(bytes[sos + 2]) * 256 + Int(bytes[sos + 3])
        let pixel = try requireValue((entropy..<bytes.count - 2).first { bytes[$0] != 0xff && ($0 == entropy || bytes[$0 - 1] != 0xff) })
        bytes[pixel] ^= bytes[pixel] == 0xfe ? 2 : 1
        try bytes.write(to: candidate)
        let before = try tool.snapshot(source), after = try tool.snapshot(candidate)
        #expect(before.embeddedTags == after.embeddedTags)
        #expect(throws: PhotoError.self) {
            try ImagePayloadVerifier.verify(source: source, candidate: candidate, before: before, after: after, tool: tool)
        }
    }

    @Test func TIFFPixelMutationIsRejectedEvenWithIdenticalMetadata() throws {
        let source = try makePhoto("source.tiff", format: .tiff)
        let before = try tool.snapshot(source)
        let raw = try requireValue(before.embeddedTags["IFD0:StripOffsets"])
        let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        let offset = try requireValue((value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init))
        var bytes = try Data(contentsOf: source)
        bytes[offset] ^= 1
        let candidate = try makeFile("changed.tiff", contents: bytes)
        let after = try tool.snapshot(candidate)
        #expect(before.embeddedTags == after.embeddedTags)
        #expect(throws: PhotoError.self) {
            try ImagePayloadVerifier.verify(source: source, candidate: candidate, before: before, after: after, tool: tool)
        }
    }

    @Test func thumbnailMutationIsRejectedDespiteSameBinarySummary() throws {
        let sample = tool.url.deletingLastPathComponent().appendingPathComponent("t/images/Sony.jpg")
        let source = try makeFile("sony-source.jpg", contents: Data(contentsOf: sample))
        let before = try tool.snapshot(source)
        let raw = try requireValue(before.embeddedTags["IFD1:ThumbnailOffset"])
        let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        let offset = try requireValue((value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init))
        var bytes = try Data(contentsOf: source)
        bytes[offset + 8] ^= 1
        let candidate = try makeFile("sony-changed.jpg", contents: bytes)
        let after = try tool.snapshot(candidate)
        #expect(before.embeddedTags == after.embeddedTags)
        #expect(throws: PhotoError.self) {
            try ImagePayloadVerifier.verify(source: source, candidate: candidate, before: before, after: after, tool: tool)
        }
    }

    @Test func opaquePreviewWithoutReliableExtractionIsRejected() throws {
        let source = try makePhoto("opaque-preview.jpg")
        let snapshot = try tool.snapshot(source)
        var tags = snapshot.embeddedTags
        tags["Sony:PreviewImage"] = "\"(Binary data 128 bytes, use -b option to extract)\""
        let opaque = ExifTool.Snapshot(metadata: snapshot.metadata, warnings: snapshot.warnings, embeddedTags: tags)
        // A matching length string is not evidence that private image bytes
        // survived. If the extractor cannot return them, refuse the candidate.
        #expect(throws: PhotoError.self) {
            try ImagePayloadVerifier.verify(source: source, candidate: source,
                before: opaque, after: opaque, tool: tool)
        }
    }

    @Test func TIFFBoundsAndMissingMainPixelRangesAreRejected() throws {
        let source = try makePhoto("source.tiff", format: .tiff)
        let before = try tool.snapshot(source)
        var invalid = before.embeddedTags
        invalid["IFD0:StripOffsets"] = "18446744073709551615"
        let outOfBounds = ExifTool.Snapshot(metadata: before.metadata, warnings: before.warnings, embeddedTags: invalid)
        #expect(throws: PhotoError.self) {
            try ImagePayloadVerifier.verify(source: source, candidate: source, before: before, after: outOfBounds, tool: tool)
        }
        let thumbnailOnly = ExifTool.Snapshot(metadata: before.metadata, warnings: "", embeddedTags:
            ["IFD1:ThumbnailOffset": "0", "IFD1:ThumbnailLength": "2"])
        #expect(throws: PhotoError.self) {
            try ImagePayloadVerifier.verify(source: source, candidate: source, before: thumbnailOnly, after: thumbnailOnly, tool: tool)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"] != nil))
    func realSonyRAWPixelMutationIsRejectedWithoutComputingAHash() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"] else { return }
        let source = URL(fileURLWithPath: path)
        let before = try tool.snapshot(source)
        let candidate = temporaryDirectory.appendingPathComponent("changed.ARW")
        try FileManager.default.copyItem(at: source, to: candidate)
        let raw = try requireValue(before.embeddedTags["SubIFD:StripOffsets"])
        let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        let offset = try requireValue((value as? NSNumber)?.uint64Value ?? (value as? String).flatMap(UInt64.init))
        let handle = try FileHandle(forUpdating: candidate)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var data = try requireValue(handle.read(upToCount: 1))
        data[0] ^= 1
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        let after = try tool.snapshot(candidate)
        #expect(before.embeddedTags == after.embeddedTags)
        #expect(throws: PhotoError.self) {
            try ImagePayloadVerifier.verify(source: source, candidate: candidate, before: before, after: after, tool: tool)
        }
    }
}
