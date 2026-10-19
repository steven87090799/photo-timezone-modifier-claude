import Darwin
import Foundation
import Testing
@testable import PhotoTimezoneApp
@testable import TimezoneCore

struct CompressionExportSafetyTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressionExportSafety-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func setMarker(_ marker: Data, on file: URL) throws {
        let result = marker.withUnsafeBytes {
            setxattr(file.path, "com.example.archival-export", $0.baseAddress, marker.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func marker(on file: URL) throws -> Data {
        let size = getxattr(file.path, "com.example.archival-export", nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var data = Data(count: size)
        let actual = data.withUnsafeMutableBytes {
            getxattr(file.path, "com.example.archival-export", $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard actual == size else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return data
    }

    @Test func singleExportPreservesBytesAndFilesystemMetadata() throws {
        try withFolder { folder in
            let source = folder.appendingPathComponent("result.jpg")
            let target = folder.appendingPathComponent("saved.jpg")
            let bytes = Data((0..<65537).map { UInt8($0 % 251) })
            try bytes.write(to: source)
            let marker = Data("Finder and archive metadata".utf8)
            try setMarker(marker, on: source)
            let modified = Date(timeIntervalSince1970: 1_234_567_890)
            try FileManager.default.setAttributes([.modificationDate: modified, .posixPermissions: 0o640], ofItemAtPath: source.path)
            let original = try FileIdentity.read(source)

            try CompressionExports.saveFile(source, to: target)
            #expect(try Data(contentsOf: target) == bytes)
            #expect(try self.marker(on: target) == marker)
            let saved = try FileIdentity.read(target)
            #expect(saved.modifiedSeconds == original.modifiedSeconds)
            #expect(saved.modifiedNanoseconds == original.modifiedNanoseconds)
            #expect(saved.mode & 0o7777 == original.mode & 0o7777)
            try original.verify(source)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["result.jpg", "saved.jpg"])
        }
    }

    @Test func existingFilesAndSourceAliasesAreNeverOverwritten() throws {
        try withFolder { folder in
            let source = folder.appendingPathComponent("source.jpg")
            let occupied = folder.appendingPathComponent("occupied.jpg")
            let alias = folder.appendingPathComponent("source-alias.jpg")
            let symlink = folder.appendingPathComponent("source-link.jpg")
            try Data("verified result".utf8).write(to: source)
            try Data("irreplaceable existing photo".utf8).write(to: occupied)
            try FileManager.default.linkItem(at: source, to: alias)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
            let original = try FileIdentity.read(source)
            for target in [source, occupied, alias, symlink] {
                #expect(throws: (any Error).self) { try CompressionExports.saveFile(source, to: target) }
            }
            #expect(try Data(contentsOf: occupied) == Data("irreplaceable existing photo".utf8))
            try original.verify(source)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 4)
        }
    }

    @Test func batchPreflightRejectsCollisionsBeforePublishingAnyOutput() throws {
        try withFolder { folder in
            let source = folder.appendingPathComponent("source.jpg")
            let output = folder.appendingPathComponent("exports", isDirectory: true)
            try Data("verified result".utf8).write(to: source)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let occupied = output.appendingPathComponent("occupied.jpg")
            try Data("original photo".utf8).write(to: occupied)
            #expect(throws: (any Error).self) {
                try CompressionExports.saveAll([(source, "first.jpg"), (source, "occupied.jpg")], in: output)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["occupied.jpg"])
            #expect(try Data(contentsOf: occupied) == Data("original photo".utf8))
        }
    }

    @Test func zipRetainsBytesAndExtendedAttributesAndRefusesOverwrite() throws {
        try withFolder { folder in
            let source = folder.appendingPathComponent("result.jpg")
            let archive = folder.appendingPathComponent("photos.zip")
            let extracted = folder.appendingPathComponent("extracted", isDirectory: true)
            let bytes = Data("image bytes and embedded metadata".utf8)
            let marker = Data("archival attribute".utf8)
            try bytes.write(to: source)
            try setMarker(marker, on: source)
            try CompressionExports.zip([(source, "photo.jpg")], to: archive)
            let originalArchive = try Data(contentsOf: archive)
            #expect(throws: (any Error).self) {
                try CompressionExports.zip([(source, "photo.jpg")], to: archive)
            }
            #expect(try Data(contentsOf: archive) == originalArchive)

            let extract = Process(); extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            extract.arguments = ["-x", "-k", archive.path, extracted.path]
            try extract.run(); extract.waitUntilExit()
            #expect(extract.terminationStatus == 0)
            let saved = extracted.appendingPathComponent("photo.jpg")
            #expect(try Data(contentsOf: saved) == bytes)
            #expect(try self.marker(on: saved) == marker)
        }
    }
}
