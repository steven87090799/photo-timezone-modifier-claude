import Foundation
import Testing
@testable import TimezoneCore
#if canImport(Darwin)
import Darwin

final class FileSafetyTests: TemporaryDirectoryTestCase {
    @Test func convertedImagePreservesSafeFlagsAndRejectsLockedSource() throws {
        let source = try makeFile("flag-source.png")
        let output = try makeFile("flag-output.jpg")
        defer { _ = chflags(source.path, 0); _ = chflags(output.path, 0) }
        #expect(chflags(source.path, UInt32(UF_HIDDEN | UF_NODUMP)) == 0)
        try FileExport.preserveConvertedImageAttributes(from: source, to: output)
        var info = stat()
        #expect(lstat(output.path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_HIDDEN | UF_NODUMP) == UInt32(UF_HIDDEN | UF_NODUMP))
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        let original = try Data(contentsOf: source), encoded = try Data(contentsOf: output)
        #expect(throws: PhotoError.self) { try FileExport.preserveConvertedImageAttributes(from: source, to: output) }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: output) == encoded)
    }
    @Test func convertedImageRetainsDenyACLWithoutChangingOwnersOrImageBytes() throws {
        let source = try makeFile("acl-source.png")
        let bytes = Data("encoded image bytes must stay unchanged".utf8)
        let output = try makeFile("acl-output.jpg", contents: bytes)
        func chmod(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = arguments
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try chmod(["+a", "everyone deny write,append", source.path])
        defer { try? chmod(["-N", source.path]); try? chmod(["-N", output.path]) }
        let sourceIdentity = try FileIdentity.read(source)
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)

        try FileExport.preserveConvertedImageAttributes(from: source, to: output)

        // Exercise the permission independently of the ACL-copy implementation:
        // the output owner has POSIX write permission but the deny entry wins.
        let descriptor = Darwin.open(output.path, O_WRONLY)
        if descriptor >= 0 { Darwin.close(descriptor) }
        #expect(descriptor == -1)
        #expect(try Data(contentsOf: output) == bytes)
        try sourceIdentity.verify(source)
        let sourceAfter = try FileManager.default.attributesOfItem(atPath: source.path)
        let outputAfter = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect(sourceAfter[.ownerAccountID] as? NSNumber == sourceAttributes[.ownerAccountID] as? NSNumber)
        #expect(sourceAfter[.groupOwnerAccountID] as? NSNumber == sourceAttributes[.groupOwnerAccountID] as? NSNumber)
        #expect(outputAfter[.ownerAccountID] as? NSNumber == outputAttributes[.ownerAccountID] as? NSNumber)
        #expect(outputAfter[.groupOwnerAccountID] as? NSNumber == outputAttributes[.groupOwnerAccountID] as? NSNumber)
    }

    @Test func convertedImageRetainsFinderTagsCustomAttributesDatesAndPermissions() throws {
        let source = try makeFile("original.tiff", contents: Data("original container".utf8))
        let outputBytes = Data("different encoded pixels and container".utf8)
        let output = try makeFile("converted.jpg", contents: outputBytes)
        let finderTags = try PropertyListSerialization.data(fromPropertyList: ["珍藏\n6", "家庭\n4"], format: .binary, options: 0)
        try set("com.apple.metadata:_kMDItemUserTags", finderTags, on: source)
        let custom = Data([0, 1, 2, 0xff, 0x7f])
        try set("com.example.archival-photo", custom, on: source)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let modified = Date(timeIntervalSince1970: 1_234_567_890)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified,
                                               .posixPermissions: 0o640], ofItemAtPath: source.path)
        let sourceIdentity = try FileIdentity.read(source)

        try FileExport.preserveConvertedImageAttributes(from: source, to: output)

        #expect(try Data(contentsOf: output) == outputBytes)
        #expect(try read("com.apple.metadata:_kMDItemUserTags", from: output) == finderTags)
        #expect(try read("com.example.archival-photo", from: output) == custom)
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect(attrs[.creationDate] as? Date == created)
        #expect(attrs[.modificationDate] as? Date == modified)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        try sourceIdentity.verify(source)
    }

    @Test func convertedImageRetainsDestinationQuarantineAndAddsMissingSourceMarker() throws {
        let source = try makeFile("source.png")
        let output = try makeFile("output.jpg")
        let sourceMarker = Data("0083;00000000;PhotoTimezoneTest;".utf8)
        let destinationMarker = Data("0083;00000001;PhotoTimezoneTest;".utf8)
        try set("com.apple.quarantine", sourceMarker, on: source)
        try set("com.apple.quarantine", destinationMarker, on: output)
        try FileExport.preserveConvertedImageAttributes(from: source, to: output)
        #expect(try read("com.apple.quarantine", from: output) == destinationMarker)

        let unmarked = try makeFile("unmarked.jpg")
        if getxattr(unmarked.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            #expect(removexattr(unmarked.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0)
        }
        try FileExport.preserveConvertedImageAttributes(from: source, to: unmarked)
        #expect(try read("com.apple.quarantine", from: unmarked) == sourceMarker)
    }

    @Test func conversionRejectsResourceForkAndFormatSpecificFinderType() throws {
        let resourceSource = try makeFile("with-resource.tiff")
        let resourceOutput = try makeFile("from-resource.jpg", contents: Data("encoded result".utf8))
        try set("com.apple.ResourceFork", Data("irreplaceable original format data".utf8), on: resourceSource)
        let resourceIdentity = try FileIdentity.read(resourceSource)
        let outputIdentity = try FileIdentity.read(resourceOutput)
        #expect(throws: (any Error).self) {
            try FileExport.preserveConvertedImageAttributes(from: resourceSource, to: resourceOutput)
        }
        try resourceIdentity.verify(resourceSource)
        try outputIdentity.verify(resourceOutput)

        let finderSource = try makeFile("finder-type.tiff")
        let finderOutput = try makeFile("finder-type.jpg")
        var finder = Data(repeating: 0, count: 32)
        finder.replaceSubrange(0..<4, with: Data("TIFF".utf8))
        try set("com.apple.FinderInfo", finder, on: finderSource)
        let finderIdentity = try FileIdentity.read(finderSource)
        #expect(throws: (any Error).self) {
            try FileExport.preserveConvertedImageAttributes(from: finderSource, to: finderOutput)
        }
        try finderIdentity.verify(finderSource)
    }

    @Test func fullMediaSyncSucceedsForLocalRegularFileAndRejectsSymlinks() throws {
        let source = try makeFile("backup-to-sync.jpg")
        let identity = try FileIdentity.read(source)
        try SafeFileTransaction.fullSyncFile(source)
        try identity.verify(source)

        let alias = temporaryDirectory.appendingPathComponent("backup-alias.jpg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        #expect(throws: (any Error).self) { try SafeFileTransaction.fullSyncFile(alias) }
        try identity.verify(source)
    }

    private func set(_ name: String, _ value: Data, on file: URL) throws {
        let result = value.withUnsafeBytes {
            setxattr(file.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func read(_ name: String, from file: URL) throws -> Data {
        let count = getxattr(file.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes {
            getxattr(file.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW)
        }
        guard actual == count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return data
    }

    @Test func nativeCopyRetainsDestinationSecurityAttributes() throws {
        let source = try makeFile("source.jpg")
        let candidate = temporaryDirectory.appendingPathComponent("candidate.jpg")
        let marker = Data("original Finder metadata".utf8)
        let sourceQuarantine = Data("0083;00000000;PhotoTimezoneTest;".utf8)
        try set("com.example.photo-timezone-test", marker, on: source)
        try set("com.apple.quarantine", sourceQuarantine, on: source)
        // Exercise the Foundation fallback used when clonefile returns EXDEV.
        try FileManager.default.copyItem(at: source, to: candidate)
        let destinationQuarantine = Data("0083;00000001;PhotoTimezoneTest;".utf8)
        try set("com.apple.quarantine", destinationQuarantine, on: candidate)
        let provenance = try? read("com.apple.provenance", from: candidate)

        try FileSafety.preserveAndVerifyFileAttributes(from: source, to: candidate)

        #expect(try read("com.example.photo-timezone-test", from: candidate) == marker)
        #expect(try read("com.apple.quarantine", from: candidate) == destinationQuarantine)
        #expect(try read("com.apple.quarantine", from: source) == sourceQuarantine)
        #expect((try? read("com.apple.provenance", from: candidate)) == provenance)
    }

    @Test func alteredOrdinaryAttributeStillBlocksPublication() throws {
        let source = try makeFile("source.jpg")
        let candidate = temporaryDirectory.appendingPathComponent("candidate.jpg")
        try set("com.example.photo-timezone-test", Data("before".utf8), on: source)
        try FileManager.default.copyItem(at: source, to: candidate)
        try set("com.example.photo-timezone-test", Data("after".utf8), on: candidate)
        do {
            try FileSafety.preserveAndVerifyFileAttributes(from: source, to: candidate)
            Issue.record("Expected altered ordinary attribute to be rejected")
        } catch let error as PhotoError {
            #expect(error.message.contains("com.example.photo-timezone-test"))
        }
    }

    @Test func missingSourceQuarantineStillBlocksPublication() throws {
        let source = try makeFile("source.jpg")
        let candidate = temporaryDirectory.appendingPathComponent("candidate.jpg")
        try set("com.apple.quarantine", Data("0083;00000000;PhotoTimezoneTest;".utf8), on: source)
        try FileManager.default.copyItem(at: source, to: candidate)
        #expect(removexattr(candidate.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0)
        do {
            try FileSafety.preserveAndVerifyFileAttributes(from: source, to: candidate)
            Issue.record("Expected missing quarantine to be rejected")
        } catch let error as PhotoError {
            #expect(error.message.contains("隔離標記"))
        }
    }
}
#endif
