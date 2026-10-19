import Foundation
import Testing
@testable import TimezoneCore

@Suite(.serialized)
struct MetadataStructureTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func newJPEGStructureDamageCannotPassReadableMetadataChecks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StructureGate-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = root.appendingPathComponent(".build/vendor-exiftool/t/images/Sony.jpg")
        let candidate = folder.appendingPathComponent("candidate.jpg")
        try FileManager.default.copyItem(at: original, to: candidate)
        let tool = ExifTool(url: root.appendingPathComponent(".build/vendor-exiftool/exiftool"))
        let write = try tool.execute(["-overwrite_original", "-ExifIFD:ExifVersion=0231", "-ExifIFD:OffsetTimeOriginal=+08:00", candidate.path])
        #expect(write.status == 0)
        try MetadataStructureVerifier.verify(source: original, candidate: candidate, tool: tool)
        let bytes = try Data(contentsOf: candidate)
        #expect(bytes.suffix(2) == Data([0xff, 0xd9]))
        try bytes.dropLast(2).write(to: candidate)
        #expect(throws: PhotoError.self) {
            try MetadataStructureVerifier.verify(source: original, candidate: candidate, tool: tool)
        }
    }

    @Test func existingCameraStructureWarningsAreComparedWithoutBeingInventedOrSuppressed() throws {
        let original = root.appendingPathComponent(".build/real-arw-fixtures/ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW")
        guard FileManager.default.fileExists(atPath: original.path) else { return }
        let tool = ExifTool(url: root.appendingPathComponent(".build/vendor-exiftool/exiftool"))
        let diagnostics = try MetadataStructureVerifier.verify(source: original, candidate: original, tool: tool)
        #expect(!diagnostics.isEmpty, "Existing factory diagnostics must remain visible to callers")
    }
}
