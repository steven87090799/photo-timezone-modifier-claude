import Foundation
import Testing
@testable import TimezoneCore

final class TransactionStoreTests: TemporaryDirectoryTestCase {
    @Test func finalCommitSurvivesFailureAfterArchiveRename() throws {
        let photo = try makeFile("photo.jpg")
        let directory = try makeDirectory("transactions")
        let store = try TransactionStore(directory: directory) { _ in
            throw PhotoError("Simulated failure synchronizing the emptied active directory")
        }
        let manifest = TransactionManifest(
            version: 4, id: UUID(), source: photo, target: photo,
            candidate: SafeFileTransaction.temporaryPhoto(beside: photo), backup: nil,
            sourceIdentity: try FileIdentity.read(photo), candidateIdentity: nil,
            originalDates: [:], oldOffsets: [:], newOffsets: [:], sidecarTargets: [],
            publishedSidecars: [], phase: .committed, detail: "Verified photo"
        )
        try store.finish(manifest)
        #expect(store.issues.count == 1)
        #expect(try store.unfinished().isEmpty)
        let archived = store.history.appendingPathComponent("\(manifest.id).json")
        let reopened = try TransactionStore(directory: directory)
        try reopened.finish(manifest)
        #expect(FileManager.default.fileExists(atPath: archived.path))
        #expect(!FileManager.default.fileExists(atPath: reopened.active.appendingPathComponent(archived.lastPathComponent).path))
    }

    @Test func activeRecordWithUnknownVersionRemainsProtected() throws {
        let photo = try makeFile("photo.jpg")
        let directory = try makeDirectory("transactions")
        let store = try TransactionStore(directory: directory)
        let record = TransactionManifest(version: 99, id: UUID(), source: photo, target: photo,
            candidate: SafeFileTransaction.temporaryPhoto(beside: photo), backup: nil,
            sourceIdentity: try FileIdentity.read(photo), candidateIdentity: nil, originalDates: [:],
            oldOffsets: [:], newOffsets: [:], sidecarTargets: [], publishedSidecars: [],
            phase: .committed, detail: "A future journal version")
        let path = store.active.appendingPathComponent("\(record.id).json")
        let bytes = try JSONEncoder().encode(record)
        try bytes.write(to: path)
        let reopened = try TransactionStore(directory: directory)
        #expect(reopened.hasUnreadableActive)
        #expect(try reopened.unfinished().isEmpty)
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test func oversizedRecordIsRejectedBeforeReplacingAnActiveRecord() throws {
        let photo = try makeFile("photo.jpg")
        let store = try TransactionStore(directory: makeDirectory("transactions"))
        let manifest = TransactionManifest(
            version: 4, id: UUID(), source: photo, target: photo,
            candidate: SafeFileTransaction.temporaryPhoto(beside: photo), backup: nil,
            sourceIdentity: try FileIdentity.read(photo), candidateIdentity: nil,
            originalDates: [:], oldOffsets: [:], newOffsets: [:], sidecarTargets: [],
            publishedSidecars: [], phase: .prepared, detail: "Normal-size record"
        )
        try store.save(manifest)
        var oversized = manifest
        oversized.detail = String(repeating: "x", count: 1024 * 1024)
        #expect(throws: PhotoError.self) { try store.save(oversized) }
        let path = store.active.appendingPathComponent("\(manifest.id).json")
        #expect(try JSONDecoder().decode(TransactionManifest.self, from: Data(contentsOf: path)) == manifest)
    }
}
