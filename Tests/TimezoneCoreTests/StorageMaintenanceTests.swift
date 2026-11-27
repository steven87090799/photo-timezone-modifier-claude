import Foundation
import Testing
@testable import TimezoneCore

final class StorageMaintenanceTests: TemporaryDirectoryTestCase {
    @Test func orphanSidecarCandidatesKeepTheirExtensionsAndOriginalsAreRetained() throws {
        let photo = try makeFile("photo.jpg")
        let support = try makeDirectory("support")
        let orphanNames = ["xmp", "XmP", "on1", "acr"].map {
            ".sidecar-\(UUID().uuidString).\($0)"
        } + [".sidecar-\(UUID().uuidString)"]
        let orphans = try orphanNames.map { try makeFile($0) }
        let retainedNames = [
            "photo.xmp", "photo.xmp.before-write-\(UUID().uuidString).backup",
            ".sidecar-not-a-uuid.xmp", ".sidecar-\(UUID().uuidString).xmp.backup",
            ".sidecar-\(UUID().uuidString).txt", ".sidecar-\(UUID().uuidString).",
            ".sidecar-\(UUID().uuidString).xmp", ".photo-timezone-\(UUID().uuidString).jpg"
        ]
        let retained = try retainedNames.map { try makeFile($0) }
        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions"))
        let manifest = TransactionManifest(
            version: 4, id: UUID(), source: photo, target: photo,
            candidate: SafeFileTransaction.temporaryPhoto(beside: photo), backup: nil,
            sourceIdentity: try FileIdentity.read(photo), candidateIdentity: nil,
            sidecarCandidateIdentities: Dictionary(uniqueKeysWithValues: try orphans.map { ($0.path, try FileIdentity.read($0)) }),
            originalDates: [:], oldOffsets: [:], newOffsets: [:], sidecarTargets: [], publishedSidecars: [],
            phase: .aborted, detail: "Cleanup fixture")
        try store.finish(manifest)

        let usage = try StorageMaintenance.snapshot(photoURLs: [photo], support: support)
        #expect(usage.orphanCandidates == orphans.count)
        let approved = try StorageMaintenance.orphanCandidates(photoURLs: [photo], support: support)
        #expect(Set(approved.map(\.url)) == Set(orphans))
        let replaced = try #require(orphans.first)
        try Data("new file".utf8).write(to: replaced, options: .atomic)
        let result = try StorageMaintenance.cleanOrphanCandidates(photoURLs: [photo], support: support, approved: approved)
        #expect(result.removedFiles == orphans.count - 1)
        for orphan in orphans.dropFirst() { #expect(!FileManager.default.fileExists(atPath: orphan.path)) }
        #expect(FileManager.default.fileExists(atPath: replaced.path))
        for file in [photo] + retained { #expect(FileManager.default.fileExists(atPath: file.path)) }
    }

    @Test func activeSidecarCandidatesAreExcludedFromCleanup() throws {
        let photo = try makeFile("photo.jpg")
        let support = try makeDirectory("support")
        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions"))
        let sidecar = try makeFile(".sidecar-\(UUID().uuidString).xmp")
        let sourceIdentity = try FileIdentity.read(photo)
        let manifest = TransactionManifest(
            version: 3, id: UUID(), source: photo, target: photo,
            candidate: SafeFileTransaction.temporaryPhoto(beside: photo), backup: nil,
            sourceIdentity: sourceIdentity, targetIdentityBefore: sourceIdentity,
            candidateIdentity: nil,
            sidecarCandidateIdentities: [sidecar.path: try FileIdentity.read(sidecar)],
            originalDates: [:], oldOffsets: [:], newOffsets: [:], sidecarTargets: [],
            publishedSidecars: [], phase: .publicationUnconfirmed, detail: "Needs review"
        )
        try store.save(manifest)

        #expect(try StorageMaintenance.snapshot(photoURLs: [photo], support: support).orphanCandidates == 0)
        let result = try StorageMaintenance.cleanOrphanCandidates(photoURLs: [photo], support: support)
        #expect(result.removedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }
}
