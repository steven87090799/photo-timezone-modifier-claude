import Foundation
import Testing
@testable import TimezoneCore

@Suite(.serialized)
final class BundleRestoreTests: TemporaryDirectoryTestCase {
    private let tool: ExifTool
    private var records: URL { temporaryDirectory.appendingPathComponent("Transactions") }

    override init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = ProcessInfo.processInfo.environment["TEST_EXIFTOOL_PATH"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent(".build/vendor-exiftool/exiftool")
        tool = ExifTool(url: url, persistent: true)
        try super.init()
    }

    private func fixture() throws -> (photo: URL, sidecar: URL) {
        let photo = try makePhoto("photo.jpg")
        let seeded = try tool.execute(["-overwrite_original", "-DateTimeOriginal=2021:04:05 06:07:08",
            "-CreateDate=2021:04:05 06:07:08", "-ModifyDate=2021:04:05 06:07:08",
            "-OffsetTimeOriginal=+01:00", "-OffsetTimeDigitized=+01:00", "-OffsetTime=+01:00", photo.path])
        #expect(seeded.status == 0)
        let sidecar = try makeFile("photo.xmp", contents: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" exif:DateTimeOriginal="2021-04-05T06:07:08.123+01:00" dc:description="Original archive description"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        return (photo, sidecar)
    }

    @discardableResult
    private func write(_ photo: URL, minutes: Int = 480) throws -> PhotoItem {
        var item = PhotoItem(url: photo)
        try IntegratedWriter.write(item: &item, tool: tool, offset: UTCOffset(minutes: minutes),
            mode: .replaceAll, options: .appDefault, plan: nil,
            store: TransactionStore(directory: records), sidecarIndex: SidecarIndex(), cancellation: CancellationToken())
        #expect(item.status == .success)
        return item
    }

    private func restore(_ photo: URL) throws -> PhotoItem {
        var item = PhotoItem(url: photo)
        try BundleRestore.restore(item: &item, tool: tool,
            store: TransactionStore(directory: records), cancellation: CancellationToken())
        return item
    }

    @Test func repeatedWritesRestoreCanonicalPhotoAndSidecarByteForByte() throws {
        let files = try fixture()
        let originalPhoto = try Data(contentsOf: files.photo)
        let originalSidecar = try Data(contentsOf: files.sidecar)
        try write(files.photo)
        try write(files.photo, minutes: -240)
        let latestSidecar = try Data(contentsOf: files.sidecar)
        #expect(latestSidecar != originalSidecar)
        let result = try restore(files.photo)
        #expect(result.status == .success)
        #expect(try Data(contentsOf: files.photo) == originalPhoto)
        #expect(try Data(contentsOf: files.sidecar) == originalSidecar)
        let retained = try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("photo.xmp.before-restore-") }
        #expect(retained.count == 1)
        #expect(try Data(contentsOf: retained[0]) == latestSidecar)
    }

    @Test func missingOriginalSidecarIsRecreatedFromPinnedBackup() throws {
        let files = try fixture()
        let originalSidecar = try Data(contentsOf: files.sidecar)
        try write(files.photo)
        try FileManager.default.removeItem(at: files.sidecar)
        #expect(try restore(files.photo).status == .success)
        #expect(try Data(contentsOf: files.sidecar) == originalSidecar)
    }

    @Test func replacedSidecarBackupRejectsRestoreBeforeAnyVisibleChange() throws {
        let files = try fixture()
        try write(files.photo)
        let store = try TransactionStore(directory: records)
        let backups = try store.canonicalSidecarBackups(originalBackup(for: files.photo), source: files.photo)
        let backup = try requireValue(backups[files.sidecar.path]?.url)
        try Data("replaced backup".utf8).write(to: backup, options: .atomic)
        let photoBefore = try Data(contentsOf: files.photo)
        let sidecarBefore = try Data(contentsOf: files.sidecar)
        #expect(throws: PhotoError.self) { try restore(files.photo) }
        #expect(try Data(contentsOf: files.photo) == photoBefore)
        #expect(try Data(contentsOf: files.sidecar) == sidecarBefore)
    }

    @Test func legacySidecarRecordWithoutIdentityCannotClaimFullRestore() throws {
        let files = try fixture()
        let result = try write(files.photo)
        let history = records.appendingPathComponent("history")
            .appendingPathComponent("\(try requireValue(result.transactionID).uuidString).json")
        var record = try JSONDecoder().decode(TransactionManifest.self, from: Data(contentsOf: history))
        record.sidecarBackupIdentities = nil
        try JSONEncoder().encode(record).write(to: history)
        let before = try Data(contentsOf: files.photo)
        #expect(throws: PhotoError.self) { try restore(files.photo) }
        #expect(try Data(contentsOf: files.photo) == before)
    }

    @Test func sidecarAddedAfterOriginalBackupBlocksRestore() throws {
        let files = try fixture()
        try write(files.photo)
        let additional = try makeFile("photo.jpg.xmp", contents: try Data(contentsOf: files.sidecar))
        let before = try Data(contentsOf: files.photo)
        #expect(throws: PhotoError.self) { try restore(files.photo) }
        #expect(try Data(contentsOf: files.photo) == before)
        #expect(FileManager.default.fileExists(atPath: additional.path))
    }

    @Test func hardlinkedSidecarBlocksInPlaceWriteWithoutChangingEitherLink() throws {
        let files = try fixture()
        let alias = temporaryDirectory.appendingPathComponent("other.xmp")
        try FileManager.default.linkItem(at: files.sidecar, to: alias)
        let beforePhoto = try Data(contentsOf: files.photo)
        let beforeSidecar = try Data(contentsOf: files.sidecar)
        #expect(throws: PhotoError.self) { try write(files.photo) }
        #expect(try Data(contentsOf: files.photo) == beforePhoto)
        #expect(try Data(contentsOf: files.sidecar) == beforeSidecar)
        #expect(try Data(contentsOf: alias) == beforeSidecar)
        #expect(!FileManager.default.fileExists(atPath: originalBackup(for: files.photo).path))
    }

    @Test func copyPreservesBothSupportedHardlinkedSidecarNames() throws {
        let files = try fixture()
        let alias = temporaryDirectory.appendingPathComponent("photo.jpg.xmp")
        try FileManager.default.linkItem(at: files.sidecar, to: alias)
        let originalPhoto = try Data(contentsOf: files.photo)
        let originalSidecar = try Data(contentsOf: files.sidecar)
        let output = try makeDirectory("output")
        let plan = try DestinationPlan(destination: output, roots: [files.photo])
        var item = PhotoItem(url: files.photo)
        try IntegratedWriter.write(item: &item, tool: tool, offset: UTCOffset(minutes: 480),
            mode: .replaceAll, options: .appDefault, plan: plan,
            store: TransactionStore(directory: records), sidecarIndex: SidecarIndex(), cancellation: CancellationToken())
        #expect(item.status == .success)
        let first = output.appendingPathComponent("photo.xmp")
        let second = output.appendingPathComponent("photo.jpg.xmp")
        #expect(try tool.readSidecar(first).dates["XMP-exif:DateTimeOriginal"]?.hasSuffix("+08:00") == true)
        #expect(try tool.readSidecar(second).dates["XMP-exif:DateTimeOriginal"]?.hasSuffix("+08:00") == true)
        #expect(try FileIdentity.read(first).inode != FileIdentity.read(second).inode)
        #expect(try Data(contentsOf: files.photo) == originalPhoto)
        #expect(try Data(contentsOf: files.sidecar) == originalSidecar)
        #expect(try Data(contentsOf: alias) == originalSidecar)
    }

    @Test func rollbackRestoresPublishedSidecarAndRetainsBothBackups() throws {
        let target = try makeFile("rollback.xmp", contents: Data("current edits".utf8))
        let current = try FileIdentity.read(target)
        let original = try makeFile("rollback-original.backup", contents: Data("original version".utf8))
        let previous = temporaryDirectory.appendingPathComponent("rollback-previous.backup")
        try SafeFileTransaction.copyAndSync(target, to: previous)
        let stage = SafeFileTransaction.temporaryPhoto(beside: target)
        try SafeFileTransaction.copyAndSync(original, to: stage)
        let candidate = BundleRestore.Candidate(backup: original, backupIdentity: try FileIdentity.read(original),
            target: target, currentIdentity: current, stage: stage, stageIdentity: try FileIdentity.read(stage),
            previous: previous, previousIdentity: try FileIdentity.read(previous))
        try SafeFileTransaction.replace(stage, at: target)
        let result = BundleRestore.rollbackPublished([candidate])
        #expect(!result.contains("incomplete"))
        #expect(try Data(contentsOf: target) == Data("current edits".utf8))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }

    @Test func rollbackRemovesOnlyNewSidecarAndRefusesExternallyReplacedFile() throws {
        let target = temporaryDirectory.appendingPathComponent("missing-sidecar.xmp")
        let original = try makeFile("original-sidecar.backup", contents: Data("original version".utf8))
        let stage = SafeFileTransaction.temporaryPhoto(beside: target)
        try SafeFileTransaction.copyAndSync(original, to: stage)
        let candidate = BundleRestore.Candidate(backup: original, backupIdentity: try FileIdentity.read(original),
            target: target, currentIdentity: nil, stage: stage, stageIdentity: try FileIdentity.read(stage),
            previous: nil)
        try SafeFileTransaction.publishExclusive(stage, to: target)
        #expect(!BundleRestore.rollbackPublished([candidate]).contains("incomplete"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let secondStage = SafeFileTransaction.temporaryPhoto(beside: target)
        try SafeFileTransaction.copyAndSync(original, to: secondStage)
        let replaced = BundleRestore.Candidate(backup: original, backupIdentity: try FileIdentity.read(original),
            target: target, currentIdentity: nil, stage: secondStage, stageIdentity: try FileIdentity.read(secondStage),
            previous: nil)
        try SafeFileTransaction.publishExclusive(secondStage, to: target)
        try Data("external new edits".utf8).write(to: target, options: .atomic)
        #expect(BundleRestore.rollbackPublished([replaced]).contains("incomplete"))
        #expect(try Data(contentsOf: target) == Data("external new edits".utf8))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
}
