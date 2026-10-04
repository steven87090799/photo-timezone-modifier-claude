import Foundation
import Testing
@testable import TimezoneCore
#if canImport(Darwin)
import Darwin

final class FileSafetyTests: TemporaryDirectoryTestCase {
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
