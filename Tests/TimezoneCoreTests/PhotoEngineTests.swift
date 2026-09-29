import Foundation
import Darwin
import Testing
@testable import TimezoneCore

/// Run with `swift test` (without --parallel): PhotoEngine owns a global job lock.
/// TEST_EXIFTOOL_PATH overrides the repository's pinned vendor installation.
@Suite(.serialized)
final class PhotoEngineTests: TemporaryDirectoryTestCase {
    private var tool: ExifTool!
    private var logDirectory: URL!
    private let originalDate = "2021:04:05 06:07:08"
    private let createdDate = "2021:04:05 06:07:09"
    private let modifiedDate = "2022:10:11 12:13:14"

    override init() throws {
        try super.init()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let override = ProcessInfo.processInfo.environment["TEST_EXIFTOOL_PATH"]
        let url = override.map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent(".build/vendor-exiftool/exiftool")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if override != nil {
                throw PhotoError("TEST_EXIFTOOL_PATH is not readable: \(url.path)")
            }
            throw PhotoError("Pinned ExifTool is not installed. Run scripts/prepare-exiftool.sh or set TEST_EXIFTOOL_PATH to ExifTool \(EngineResources.version).")
        }
        tool = ExifTool(url: url)
        // A wrong or broken installation is a failure, never a silent skip.
        try tool.validateVersion()
        logDirectory = temporaryDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    @Test func testBadFirstPhotoDoesNotPreventFollowingJPEGAndTIFFWrites() async throws {
        let bad = try makeFile("00-corrupt.jpg", contents: Data("plain text, not a JPEG".utf8))
        let badBytes = try Data(contentsOf: bad)
        let jpeg = try makeSeededPhoto("01-valid.jpg")
        let tiff = try makeSeededPhoto("02-valid.tiff", format: .tiff)
        let originals = try [jpeg, tiff].map { try Data(contentsOf: $0) }

        let job = await run([bad, jpeg, tiff], operation: .write(offset: UTCOffset(minutes: 345), mode: .fillMissing))
        let items = try assertJob(job, succeeded: 2, failed: 1)
        expectEqual(items.map(\.url), [bad, jpeg, tiff])
        expectEqual(items.map(\.status), [.failed, .success, .success])
        expectFalse(items[0].detail.isEmpty)
        expectEqual(try Data(contentsOf: bad), badBytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: bad).path))
        for (index, photo) in [jpeg, tiff].enumerated() {
            let metadata = try tool.inspect(photo).0
            assertOffsets(metadata, original: "+05:45", digitized: "+05:45", time: "+05:45")
            assertDates(metadata)
            expectEqual(metadata.fileType, index == 0 ? "JPEG" : "TIFF")
            expectEqual(try Data(contentsOf: originalBackup(for: photo)), originals[index])
        }
    }

    @Test func testFillMissingPreservesExistingOriginalOffsetAndFillsOtherTwoTags() async throws {
        let jpeg = try makeSeededPhoto("partial.jpg", original: "-03:30")
        let tiff = try makeSeededPhoto("partial.tiff", format: .tiff, original: "-03:30")
        for photo in [jpeg, tiff] {
            let before = try tool.inspect(photo).0
            assertOffsets(before, original: "-03:30", digitized: nil, time: nil)
            expectTrue(before.missingOffsets)
        }

        let job = await run([jpeg, tiff], operation: .write(offset: UTCOffset(minutes: 345), mode: .fillMissing))
        let items = try assertJob(job, succeeded: 2)
        for (photo, item) in zip([jpeg, tiff], items) {
            let metadata = try tool.inspect(photo).0
            assertOffsets(metadata, original: "-03:30", digitized: "+05:45", time: "+05:45")
            assertDates(metadata)
            expectFalse(metadata.missingOffsets)
            assertOffsets(try requireValue(item.metadata), original: "-03:30", digitized: "+05:45", time: "+05:45")
        }
    }

    @Test func testReplaceAllChangesEveryOffsetButPreservesEveryDate() async throws {
        let jpeg = try makeSeededPhoto("replace.jpg", original: "+09:00", digitized: "+05:45", time: "-03:30")
        let tiff = try makeSeededPhoto("replace.tiff", format: .tiff, original: "+09:00", digitized: "+05:45", time: "-03:30")
        let before = try [jpeg, tiff].map { try tool.inspect($0).0 }

        let job = await run([jpeg, tiff], operation: .write(offset: UTCOffset(minutes: -720), mode: .replaceAll))
        _ = try assertJob(job, succeeded: 2)
        for (index, photo) in [jpeg, tiff].enumerated() {
            let after = try tool.inspect(photo).0
            assertOffsets(after, original: "-12:00", digitized: "-12:00", time: "-12:00")
            assertDates(after)
            expectEqual(after.dateTimeOriginal, before[index].dateTimeOriginal)
            expectEqual(after.createDate, before[index].createDate)
            expectEqual(after.modifyDate, before[index].modifyDate)
        }
    }

    @Test func testRepeatedWritesPreserveExactFirstOriginalAndRestoreKeepsEditedCopy() async throws {
        let photo = try makeSeededPhoto("round-trip.tiff", format: .tiff, original: "+01:00")
        let originalBytes = try Data(contentsOf: photo)
        let originalHash = try digest(of: photo)
        let backup = originalBackup(for: photo)

        let first = await run([photo], operation: .write(offset: UTCOffset(minutes: 840), mode: .replaceAll))
        _ = try assertJob(first, succeeded: 1)
        expectEqual(try Data(contentsOf: backup), originalBytes)
        expectEqual(try digest(of: backup), originalHash)
        let firstEditHash = try digest(of: photo)
        expectNotEqual(firstEditHash, originalHash)

        let second = await run([photo], operation: .write(offset: UTCOffset(minutes: -15), mode: .replaceAll))
        _ = try assertJob(second, succeeded: 1)
        expectEqual(try Data(contentsOf: backup), originalBytes, "The first _original must never be replaced")
        expectEqual(try digest(of: backup), originalHash)
        let editedBytes = try Data(contentsOf: photo)
        let editedHash = try digest(of: photo)
        expectNotEqual(editedHash, originalHash)
        expectNotEqual(editedHash, firstEditHash)
        let previousVersions = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(photo.lastPathComponent + ".before-write-") && $0.pathExtension == "backup"
        }
        expectEqual(previousVersions.count, 1)
        expectEqual(try digest(of: requireValue(previousVersions.first)), firstEditHash)
        assertOffsets(try tool.inspect(photo).0, original: "-00:15", digitized: "-00:15", time: "-00:15")

        let restored = await run([photo], operation: .restore)
        let restoredItems = try assertJob(restored, succeeded: 1)
        expectEqual(try digest(of: photo), originalHash)
        expectEqual(try Data(contentsOf: photo), originalBytes)
        expectEqual(try Data(contentsOf: backup), originalBytes, "Restoration must retain the oldest backup")
        assertOffsets(try requireValue(restoredItems.first?.metadata), original: "+01:00", digitized: nil, time: nil)
        assertDates(try tool.inspect(photo).0)
        let savedEdits = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(photo.lastPathComponent + ".before-restore-") && $0.pathExtension == "backup"
        }
        expectEqual(savedEdits.count, 1)
        let savedEdit = try requireValue(savedEdits.first)
        expectEqual(try Data(contentsOf: savedEdit), editedBytes)
        expectEqual(try digest(of: savedEdit), editedHash)
        expectEqual(Set((first.summaries + second.summaries + restored.summaries).compactMap(\.logURL)).count, 3)
        let hiddenStages = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".photo-timezone-") }
        expectTrue(hiddenStages.isEmpty)
    }

    @Test func testCancellationInFirstUpdatedCallbackLeavesRemainingPhotosByteIdentical() async throws {
        let first = try makeSeededPhoto("first.jpg")
        let second = try makeSeededPhoto("second.tiff", format: .tiff)
        let third = try makeSeededPhoto("third.jpg")
        let photos = [first, second, third]
        let originals = try photos.map { try Data(contentsOf: $0) }
        let cancellation = CancellationToken()

        let job = await run(photos, operation: .write(offset: UTCOffset(minutes: 765), mode: .replaceAll),
                            cancellation: cancellation, cancelAfterFirstUpdate: true)
        let items = try assertJob(job, succeeded: 1, cancelled: 2)
        expectTrue(cancellation.isCancelled)
        expectEqual(items.map(\.url), photos)
        expectEqual(items.map(\.status), [.success, .cancelled, .cancelled])
        expectNotEqual(try Data(contentsOf: first), originals[0])
        expectEqual(try Data(contentsOf: originalBackup(for: first)), originals[0])
        assertOffsets(try tool.inspect(first).0, original: "+12:45", digitized: "+12:45", time: "+12:45")
        for index in 1..<photos.count {
            expectEqual(try Data(contentsOf: photos[index]), originals[index])
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photos[index]).path))
            assertOffsets(try tool.inspect(photos[index]).0, original: nil, digitized: nil, time: nil)
        }
    }

    @Test func testQuotesWhitespaceNewlineDollarAndUnicodePathSurvivesWriteJournalAndRestore() async throws {
        let photo = try makeSeededPhoto("相片 folder 'quoted' \"double\" $value\t/line\nbreak $(not-a-command) `literal` 雪☃.jpg")
        let original = try Data(contentsOf: photo)
        let job = await run([photo], operation: .write(offset: UTCOffset(minutes: 330), mode: .fillMissing))
        let items = try assertJob(job, succeeded: 1)
        expectEqual(items.first?.url.path, photo.path)
        expectEqual(try Data(contentsOf: originalBackup(for: photo)), original)
        assertOffsets(try tool.inspect(photo).0, original: "+05:30", digitized: "+05:30", time: "+05:30")
        let restored = await run([photo], operation: .restore)
        _ = try assertJob(restored, succeeded: 1)
        expectEqual(try Data(contentsOf: photo), original)
    }

    @Test func testEmptyInputsAndEmptyDirectoryNeverReportSuccess() async throws {
        let empty = try makeDirectory("empty")
        for inputs: [URL] in [[], [empty]] {
            let job = await run(inputs, operation: .write(offset: UTCOffset(minutes: 0), mode: .fillMissing))
            expectTrue(try assertJob(job).isEmpty)
        }
    }

    @Test func testFillMissingWithAllOffsetsPresentSkipsWithoutCreatingBackupsOrChangingBytes() async throws {
        let jpeg = try makeSeededPhoto("complete.jpg", original: "+01:00", digitized: "+02:00", time: "+03:00")
        let tiff = try makeSeededPhoto("complete.tiff", format: .tiff, original: "-01:00", digitized: "-02:00", time: "-03:00")
        let photos = [jpeg, tiff]
        let originals = try photos.map { try Data(contentsOf: $0) }
        let job = await run(photos, operation: .write(offset: UTCOffset(minutes: 345), mode: .fillMissing))
        let items = try assertJob(job, skipped: 2)
        expectEqual(items.map(\.status), [.skipped, .skipped])
        for (index, photo) in photos.enumerated() {
            expectEqual(try Data(contentsOf: photo), originals[index])
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
            expectFalse(try tool.inspect(photo).0.missingOffsets)
        }
    }

    @Test func testReplaceAllWithMatchingOffsetsIsANoop() async throws {
        let photo = try makeSeededPhoto("matching.jpg", original: "+05:45", digitized: "+05:45", time: "+05:45")
        let original = try Data(contentsOf: photo)
        let job = await run([photo], operation: .write(offset: UTCOffset(minutes: 345), mode: .replaceAll))
        _ = try assertJob(job, skipped: 1)
        expectEqual(try Data(contentsOf: photo), original)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testFakeJPEGTextIsReportedAsFailedAndNeverBackedUp() async throws {
        let photo = try makeFile("pretend.jpg", contents: Data("This is text, despite its extension.\n".utf8))
        let original = try Data(contentsOf: photo)
        let job = await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .replaceAll))
        let items = try assertJob(job, failed: 1)
        expectEqual(items.first?.status, .failed)
        expectFalse(items.first?.detail.isEmpty ?? true)
        expectEqual(try Data(contentsOf: photo), original)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testExplicitUnsupportedExtensionIsReportedAsSkipped() async throws {
        let photo = try makeFile("unsupported.png")
        let original = try Data(contentsOf: photo)
        let job = await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .replaceAll))
        // Explicit unsupported files are visible skips, not processing errors.
        let items = try assertJob(job, skipped: 1)
        expectEqual(items.first?.status, .skipped)
        expectEqual(try Data(contentsOf: photo), original)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testInspectReadsBothFormatsWithoutMutatingOrBackingUpPhotos() async throws {
        let jpeg = try makeSeededPhoto("inspect.jpg", original: "+08:00")
        let tiff = try makeSeededPhoto("inspect.tiff", format: .tiff)
        let photos = [jpeg, tiff]
        let originals = try photos.map { try Data(contentsOf: $0) }
        let job = await run(photos, operation: .inspect)
        let items = try assertJob(job, succeeded: 2)
        expectEqual(items.map(\.status), [.ready, .ready])
        expectEqual(items.map { $0.metadata?.fileType }, ["JPEG", "TIFF"])
        expectEqual(items.first?.metadata?.offsetOriginal, "+08:00")
        for (index, photo) in photos.enumerated() {
            assertDates(try requireValue(items[index].metadata))
            expectEqual(try Data(contentsOf: photo), originals[index])
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
        }
    }

    @Test func testRestoreWithoutOriginalIsSkippedAndLeavesPhotoUnchanged() async throws {
        let photo = try makeSeededPhoto("no-backup.jpg")
        let original = try Data(contentsOf: photo)
        let job = await run([photo], operation: .restore)
        _ = try assertJob(job, skipped: 1)
        expectEqual(try Data(contentsOf: photo), original)
        let files = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        expectFalse(files.contains { $0.contains(".before-restore-") })
    }

    @Test func testInvalidExistingBackupPreventsWriteAndRestoreFromChangingEitherFile() async throws {
        let photo = try makeSeededPhoto("invalid-backup.jpg")
        let original = try Data(contentsOf: photo)
        let backup = try makeFile("invalid-backup.jpg_original", contents: Data("corrupt original backup".utf8))
        let backupBytes = try Data(contentsOf: backup)
        for operation in [JobOperation.write(offset: UTCOffset(minutes: 480), mode: .replaceAll), .restore] {
            let job = await run([photo], operation: operation)
            _ = try assertJob(job, failed: 1)
            expectEqual(try Data(contentsOf: photo), original)
            expectEqual(try Data(contentsOf: backup), backupBytes)
        }
    }

    @Test func testNonstandardOffsetIsNeverMistakenForMissing() async throws {
        let photo = try makeSeededPhoto("nonstandard.jpg")
        let setup = try tool.execute(["-overwrite_original", "-IFD0:OffsetTimeOriginal=+03:00", photo.path])
        expectEqual(setup.status, 0)
        let original = try Data(contentsOf: photo)
        let job = await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing))
        let items = try assertJob(job, failed: 1)
        expectTrue(items[0].detail.contains("非標準"))
        expectEqual(try Data(contentsOf: photo), original)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testMissingPhotoCanBeDiscoveredAndRecoveredFromBackup() async throws {
        let photo = try makeSeededPhoto("orphan.jpg")
        let original = try Data(contentsOf: photo)
        let backup = originalBackup(for: photo)
        try FileManager.default.moveItem(at: photo, to: backup)
        let preview = await run([temporaryDirectory], operation: .inspect)
        let rows = try assertJob(preview, failed: 1)
        expectEqual(rows[0].url.lastPathComponent, photo.lastPathComponent)
        // /var and /private/var can represent the same macOS temp directory.
        // Verify the discovered destination points at the actual backup.
        expectTrue(FileManager.default.contentsEqual(atPath: rows[0].url.path + "_original", andPath: backup.path))
        expectTrue(rows[0].detail.contains("原檔遺失"))
        let restored = await run([photo], operation: .restore)
        _ = try assertJob(restored, succeeded: 1)
        expectEqual(try Data(contentsOf: photo), original)
        expectEqual(try Data(contentsOf: backup), original)
    }

    @Test func testBackupFileCanBeSelectedDirectlyForMissingPhotoRecovery() async throws {
        let photo = try makeSeededPhoto("direct.tiff", format: .tiff)
        let original = try Data(contentsOf: photo)
        let backup = originalBackup(for: photo)
        try FileManager.default.moveItem(at: photo, to: backup)
        let restored = await run([backup], operation: .restore)
        let items = try assertJob(restored, succeeded: 1)
        expectEqual(items[0].url.path, photo.path)
        expectEqual(try Data(contentsOf: photo), original)
    }

    @Test func testReadTimeoutTerminatesAnUnresponsiveChild() throws {
        let script = try makeFile("sleep.pl", contents: Data("sleep 30;\n".utf8))
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try ExifTool(url: script).execute([], timeout: 0.15)
            recordFailure("Expected read timeout")
        } catch {
            expectTrue(error.localizedDescription.contains("逾時"))
        }
        expectTrue(ProcessInfo.processInfo.systemUptime - start < 4)
    }

    @Test func testInspectedFilesCannotExpandIntoNewDirectoryContents() async throws {
        let folder = try makeDirectory("was-a-photo.jpg")
        let addedPhoto = try makeSeededPhoto("was-a-photo.jpg/unreviewed.jpg")
        let original = try Data(contentsOf: addedPhoto)
        let collector = JobEventCollector()
        await PhotoEngine(exiftoolURL: tool.url, logDirectory: logDirectory).run(
            inputs: [folder], recursive: false,
            operation: .write(offset: UTCOffset(minutes: 480), mode: .replaceAll),
            cancellation: CancellationToken(), inspectedFilesOnly: true
        ) { collector.record($0) }
        _ = try assertJob(collector.snapshot(), failed: 1)
        expectEqual(try Data(contentsOf: addedPhoto), original)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: addedPhoto).path))
    }

    @Test func testReadCanBeCancelledBeforeStarting() throws {
        let token = CancellationToken()
        token.cancel()
        do {
            _ = try tool.inspect(try makeSeededPhoto("read-cancel.jpg"), cancellation: token)
            recordFailure("Expected cancellation")
        } catch is CancellationError {
            // Expected: no process launched.
        } catch {
            recordFailure("Unexpected failure: \(error)")
        }
    }

    @Test func testCameraMetadataSurvivesWriteAndBatchRead() async throws {
        let photo = try makeSeededPhoto("camera.jpg")
        let setup = try tool.execute(["-overwrite_original", "-Make=SONY", "-Model=ILCE-7M4",
            "-LensModel=FE 24-70mm F2.8 GM", "-ISO=800", "-ExposureTime=1/250", "-FNumber=2.8",
            "-FocalLength=35", "-ExifImageWidth=3", "-ExifImageHeight=2", photo.path])
        expectEqual(setup.status, 0)
        let marker = [UInt8]("preserve-finder-attributes".utf8)
        let setMarker = marker.withUnsafeBytes {
            setxattr(photo.path, "com.example.photo-timezone-test", $0.baseAddress, marker.count, 0, 0)
        }
        expectEqual(setMarker, 0)
        let batch = try tool.inspectBatch([photo], cancellation: CancellationToken())
        let before = try requireValue(batch[photo.path]).get().0
        expectEqual(before.cameraModel, "ILCE-7M4")
        expectEqual(before.make, "SONY")
        expectEqual(before.lensModel, "FE 24-70mm F2.8 GM")
        expectEqual(before.iso, "800")
        expectEqual(before.exposureTime, "1/250")
        expectEqual(before.aperture, "2.8")
        expectEqual(before.dimensions, "3 × 2")
        expectTrue((before.fileSize ?? 0) > 0)
        _ = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing)), succeeded: 1)
        let after = try tool.inspect(photo).0
        expectEqual(after.cameraModel, before.cameraModel)
        expectEqual(after.lensModel, before.lensModel)
        expectEqual(after.iso, before.iso)
        expectEqual(after.exposureTime, before.exposureTime)
        expectEqual(after.aperture, before.aperture)
        expectEqual(after.focalLength, before.focalLength)
        var savedMarker = [UInt8](repeating: 0, count: marker.count)
        let readMarker = savedMarker.withUnsafeMutableBytes {
            getxattr(photo.path, "com.example.photo-timezone-test", $0.baseAddress, marker.count, 0, 0)
        }
        expectEqual(readMarker, marker.count)
        expectEqual(savedMarker, marker)
    }

    @Test func testCopyOutputPreservesSourceTreeBytesAndNonTimezoneMetadata() async throws {
        let source = try makeDirectory("imported-camera")
        let jpeg = try makeSeededPhoto("imported-camera/day1/DSC001.jpg")
        let tiff = try makeSeededPhoto("imported-camera/day2/DSC002.tiff", format: .tiff)
        let setup = try tool.execute(["-overwrite_original", "-Artist=Test Photographer", "-Copyright=Test Rights", jpeg.path])
        expectEqual(setup.status, 0)
        let originalBytes = try [jpeg, tiff].map { try Data(contentsOf: $0) }
        let originalTags = try [jpeg, tiff].map { try tool.embeddedMetadata($0) }
        let output = try makeDirectory("output")
        let job = await run([jpeg, tiff], operation: .writeCopy(
            offset: UTCOffset(minutes: 345), mode: .fillMissing, destination: output, sourceRoots: [source]
        ))
        let items = try assertJob(job, succeeded: 2)
        let copies = [output.appendingPathComponent("imported-camera/day1/DSC001.jpg"),
                      output.appendingPathComponent("imported-camera/day2/DSC002.tiff")]
        for index in 0..<2 {
            expectEqual(try Data(contentsOf: [jpeg, tiff][index]), originalBytes[index])
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: [jpeg, tiff][index]).path))
            expectTrue(FileManager.default.fileExists(atPath: copies[index].path))
            assertOffsets(try tool.inspect(copies[index]).0, original: "+05:45", digitized: "+05:45", time: "+05:45")
            var expected = originalTags[index]
            let changed = try tool.embeddedMetadata(copies[index])
            for name in ["OffsetTimeOriginal", "OffsetTimeDigitized", "OffsetTime"] {
                expected["ExifIFD:\(name)"] = changed["ExifIFD:\(name)"]
            }
            if index == 1 { expected["IFD0:StripOffsets"] = changed["IFD0:StripOffsets"] }
            expectEqual(changed, expected)
            expectTrue(items[index].detail.contains(copies[index].path))
            expectEqual(items[index].outputURL, copies[index])
            assertOffsets(try requireValue(items[index].metadata), original: nil, digitized: nil, time: nil)
            assertOffsets(try requireValue(items[index].outputMetadata), original: "+05:45", digitized: "+05:45", time: "+05:45")
        }
    }

    @Test func testCopyCollisionFailsClosedAndAnotherPhotoStillCompletes() async throws {
        let folder = try makeDirectory("input")
        let first = try makeSeededPhoto("input/a.jpg")
        let second = try makeSeededPhoto("input/b.jpg")
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let output = try makeDirectory("output")
        let existing = try makeFile("output/input/a.jpg", contents: Data("do not overwrite".utf8))
        let existingBytes = try Data(contentsOf: existing)
        let job = await run([first, second], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [folder]
        ))
        let items = try assertJob(job, succeeded: 1, failed: 1)
        expectTrue(items[0].detail.contains("同名"))
        expectEqual(try Data(contentsOf: existing), existingBytes)
        expectEqual(try Data(contentsOf: first), originals[0])
        expectEqual(try Data(contentsOf: second), originals[1])
        assertOffsets(try tool.inspect(output.appendingPathComponent("input/b.jpg")).0,
                      original: "+08:00", digitized: "+08:00", time: "+08:00")
        // Once the user resolves a collision, only the failed source can be
        // retried; the successful second output is never touched again.
        let successfulCopy = output.appendingPathComponent("input/b.jpg")
        let successfulBytes = try Data(contentsOf: successfulCopy)
        try FileManager.default.removeItem(at: existing)
        _ = try assertJob(await run([first], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [folder]
        )), succeeded: 1)
        expectEqual(try Data(contentsOf: successfulCopy), successfulBytes)
        expectEqual(try Data(contentsOf: first), originals[0])
        assertOffsets(try tool.inspect(existing).0, original: "+08:00", digitized: "+08:00", time: "+08:00")
    }

    @Test func testCopyIncludesAlreadyCompletePhotosWithoutChangingTheirBytes() async throws {
        let photo = try makeSeededPhoto("already-complete.jpg", original: "+08:00", digitized: "+08:00", time: "+08:00")
        let original = try Data(contentsOf: photo)
        let output = try makeDirectory("output")
        let rows = try assertJob(await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [photo]
        )), succeeded: 1)
        let copy = output.appendingPathComponent(photo.lastPathComponent)
        expectEqual(try Data(contentsOf: photo), original)
        expectEqual(try Data(contentsOf: copy), original)
        expectEqual(rows[0].outputURL, copy)
        expectTrue(rows[0].detail.contains("原樣輸出"))
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testCameraJPEGThumbnailRelocationRequiresIdenticalThumbnailBytes() async throws {
        let sample = tool.url.deletingLastPathComponent().appendingPathComponent("t/images/Sony.jpg")
        let original = try Data(contentsOf: sample)
        let photo = try makeFile("camera-thumb.jpg", contents: original)
        let thumbnail = try tool.thumbnailBytes(photo)
        expectTrue(!thumbnail.isEmpty)
        let output = try makeDirectory("output")
        let copied = try assertJob(await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [photo]
        )), succeeded: 1)
        let copy = output.appendingPathComponent(photo.lastPathComponent)
        expectEqual(copied[0].outputURL, copy)
        expectEqual(try Data(contentsOf: photo), original)
        expectEqual(try tool.thumbnailBytes(copy), thumbnail)
        assertOffsets(try tool.inspect(copy).0, original: "+08:00", digitized: "+08:00", time: "+08:00")

        _ = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 480), mode: .fillMissing
        )), succeeded: 1)
        expectEqual(try Data(contentsOf: originalBackup(for: photo)), original)
        expectEqual(try tool.thumbnailBytes(photo), thumbnail)
    }

    @Test func testCopyCancellationLeavesUnprocessedSourcesAndOutputsUntouched() async throws {
        let photos = try ["one.jpg", "two.jpg", "three.jpg"].map { try makeSeededPhoto($0) }
        let originals = try photos.map { try Data(contentsOf: $0) }
        let output = try makeDirectory("output")
        let token = CancellationToken()
        let rows = try assertJob(await run(photos, operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: photos
        ), cancellation: token, cancelAfterFirstUpdate: true), succeeded: 1, cancelled: 2)
        expectEqual(rows.map(\.status), [.success, .cancelled, .cancelled])
        for (index, photo) in photos.enumerated() {
            expectEqual(try Data(contentsOf: photo), originals[index])
            expectEqual(FileManager.default.fileExists(atPath: output.appendingPathComponent(photo.lastPathComponent).path), index == 0)
        }
    }

    @Test func testCopyDestinationInsideSourceIsRejectedBeforeAnyMutation() async throws {
        let folder = try makeDirectory("camera")
        let photo = try makeSeededPhoto("camera/a.jpg")
        let original = try Data(contentsOf: photo)
        let nested = try makeDirectory("camera/output")
        let job = await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: nested, sourceRoots: [folder]
        ))
        expectEqual(job.summaries.first?.failed, 1)
        expectEqual(try Data(contentsOf: photo), original)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testCopyFromReadOnlySourceNeverNeedsToWriteAtSource() async throws {
        let photo = try makeSeededPhoto("card/card-photo.jpg")
        let original = try Data(contentsOf: photo)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: photo.path)
        let output = try makeDirectory("output")
        let job = await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [photo]
        ))
        let items = try assertJob(job, succeeded: 1)
        expectEqual(items[0].status, .success)
        expectEqual(try Data(contentsOf: photo), original)
        let copy = output.appendingPathComponent("card-photo.jpg")
        assertOffsets(try tool.inspect(copy).0, original: "+08:00", digitized: "+08:00", time: "+08:00")
    }

    @Test func testCopyOutputSymlinkCannotEscapeChosenDestination() async throws {
        let folder = try makeDirectory("source")
        let photo = try makeSeededPhoto("source/a.jpg")
        let original = try Data(contentsOf: photo)
        let output = try makeDirectory("output")
        let outside = try makeDirectory("outside")
        try FileManager.default.createSymbolicLink(
            at: output.appendingPathComponent("source"), withDestinationURL: outside
        )
        let job = await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [folder]
        ))
        let items = try assertJob(job, failed: 1)
        expectTrue(items[0].detail.contains("符號連結"))
        expectEqual(try Data(contentsOf: photo), original)
        expectFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("a.jpg").path))
    }

    @Test func testPreparedBackupWithoutReplacementLeavesOriginalIntact() throws {
        let photo = try makeSeededPhoto("interrupted.jpg")
        let original = try Data(contentsOf: photo)
        let stage = SafeFileTransaction.temporaryPhoto(beside: photo)
        try SafeFileTransaction.copyAndSync(photo, to: stage)
        let backupStage = temporaryDirectory.appendingPathComponent(".backup-in-progress")
        let backup = originalBackup(for: photo)
        try SafeFileTransaction.copyAndSync(photo, to: backupStage)
        try SafeFileTransaction.publishExclusive(backupStage, to: backup)
        // Simulates a crash before the single atomic replacement step.
        expectEqual(try Data(contentsOf: photo), original)
        expectEqual(try Data(contentsOf: backup), original)
        expectEqual(try Data(contentsOf: stage), original)
    }

    @Test func testBatchedScanContinuesAcrossCorruptAndSpecialNamesWithoutMutation() async throws {
        let seed = try makeSeededPhoto("seed.jpg")
        let original = try Data(contentsOf: seed)
        var inputs: [URL] = [try makeFile("bad.jpg", contents: Data("bad data".utf8))]
        for index in 0..<110 {
            inputs.append(try makeFile("chunk\(index)/雪\n'\"$.jpg", contents: original))
        }
        let job = await run(inputs, operation: .inspect)
        let items = try assertJob(job, succeeded: 110, failed: 1)
        expectEqual(items.map(\.url), inputs)
        for file in inputs.dropFirst() {
            expectEqual(try Data(contentsOf: file), original)
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: file).path))
        }
    }

    @Test func testReadOnlyPhotoFailsBeforeAnyBackupOrMutation() async throws {
        let photo = try makeSeededPhoto("read-only.jpg")
        let bytes = try Data(contentsOf: photo)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: photo.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: photo.path) }
        let rows = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing)), failed: 1)
        expectTrue(rows[0].detail.contains("唯讀"))
        expectEqual(try Data(contentsOf: photo), bytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_STRESS"] == "1"))
    func testThousandPhotoScanWriteAndBackupIntegrity() async throws {
        let jpeg = try makeSeededPhoto("templates/a.jpg")
        let tiff = try makeSeededPhoto("templates/b.tiff", format: .tiff)
        let originals = try [Data(contentsOf: jpeg), Data(contentsOf: tiff)]
        let root = try makeDirectory("thousand")
        var photos: [URL] = []
        for index in 0..<1000 {
            let ext = index % 2 == 0 ? "jpg" : "tiff"
            photos.append(try makeFile("thousand/day\(index / 100)/DSC\(index).\(ext)", contents: originals[index % 2]))
        }
        let bad = try makeFile("thousand/corrupt.jpg", contents: Data("not a photo".utf8))
        let scanStart = Date()
        let scanned = await run([root, photos[0]], operation: .inspect, recursive: true)
        _ = try assertJob(scanned, succeeded: 1000, failed: 1)
        let scanSeconds = Date().timeIntervalSince(scanStart)
        let writeStart = Date()
        let written = await run(photos + [bad], operation: .write(offset: UTCOffset(minutes: 345), mode: .fillMissing))
        let rows = try assertJob(written, succeeded: 1000, failed: 1)
        let writeSeconds = Date().timeIntervalSince(writeStart)
        for (index, photo) in photos.enumerated() {
            expectEqual(try Data(contentsOf: originalBackup(for: photo)), originals[index % 2])
            let metadata = try requireValue(rows[index].metadata)
            assertOffsets(metadata, original: "+05:45", digitized: "+05:45", time: "+05:45")
            assertDates(metadata)
        }
        let restored = await run(Array(photos.prefix(10)), operation: .restore)
        _ = try assertJob(restored, succeeded: 10)
        for index in 0..<10 { expectEqual(try Data(contentsOf: photos[index]), originals[index % 2]) }
        print("STRESS_RESULT photos=1000 corrupt=1 scan_seconds=\(scanSeconds) write_seconds=\(writeSeconds) verified_backups=1000 restored=10")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_STRESS"] == "1"))
    func testThousandCopyOutputsPreserveEverySource() async throws {
        let template = try makeSeededPhoto("templates/copy.jpg")
        let original = try Data(contentsOf: template)
        let root = try makeDirectory("copy-thousand")
        let output = try makeDirectory("copy-output")
        var photos: [URL] = []
        for index in 0..<1000 {
            photos.append(try makeFile("copy-thousand/day\(index / 100)/DSC\(index).jpg", contents: original))
        }
        let started = Date()
        let copied = await run(photos, operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [root]
        ))
        let failures = copied.updates.map(\.item).filter { $0.status == .failed }
        if !failures.isEmpty {
            print("STRESS_COPY_FAILURES", failures.map { "\($0.url.lastPathComponent): \($0.detail)" })
        }
        let initialRows = try assertJob(copied, succeeded: 1000 - failures.count, failed: failures.count)
        var finalRows = Dictionary(uniqueKeysWithValues: initialRows.map { ($0.url.path, $0) })
        if !failures.isEmpty {
            // The product exposes exactly this workflow: inspect/report the
            // failures, then retry only those paths after the user confirms.
            let retried = await run(failures.map(\.url), operation: .writeCopy(
                offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [root]
            ))
            for item in try assertJob(retried, succeeded: failures.count) { finalRows[item.url.path] = item }
        }
        for (index, source) in photos.enumerated() {
            expectEqual(try Data(contentsOf: source), original)
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: source).path))
            let copy = output.appendingPathComponent("copy-thousand/day\(index / 100)/DSC\(index).jpg")
            let row = try requireValue(finalRows[source.path])
            expectEqual(row.outputURL, copy)
            assertOffsets(try requireValue(row.outputMetadata), original: "+08:00", digitized: "+08:00", time: "+08:00")
            expectTrue(FileManager.default.fileExists(atPath: copy.path))
        }
        print("STRESS_COPY_RESULT photos=1000 copy_seconds=\(Date().timeIntervalSince(started)) sources_unchanged=1000 first_pass_failures=\(failures.count) retried=\(failures.count)")
    }

    private func makeSeededPhoto(
        _ name: String, format: ImageFormat = .jpeg,
        original: String? = nil, digitized: String? = nil, time: String? = nil
    ) throws -> URL {
        let photo = try makePhoto(name, format: format)
        // Overwrite is used only while constructing a disposable fixture so the
        // backup subsequently tested is created exclusively by PhotoEngine.
        let output = try tool.execute([
            "-charset", "filename=UTF8", "-overwrite_original",
            "-EXIF:DateTimeOriginal=\(originalDate)", "-EXIF:CreateDate=\(createdDate)",
            "-EXIF:ModifyDate=\(modifiedDate)",
            "-EXIF:OffsetTimeOriginal=\(original ?? "")",
            "-EXIF:OffsetTimeDigitized=\(digitized ?? "")",
            "-EXIF:OffsetTime=\(time ?? "")", photo.path
        ])
        guard output.status == 0 else { throw PhotoError("Fixture metadata setup failed: \(output.text)") }
        let metadata = try tool.inspect(photo).0
        assertDates(metadata)
        assertOffsets(metadata, original: original, digitized: digitized, time: time)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
        return photo
    }

    private func run(
        _ inputs: [URL], operation: JobOperation, recursive: Bool = false,
        cancellation: CancellationToken = CancellationToken(), cancelAfterFirstUpdate: Bool = false
    ) async -> RecordedJob {
        let collector = JobEventCollector(cancelAfterFirstUpdate: cancelAfterFirstUpdate ? cancellation : nil)
        let engine = PhotoEngine(exiftoolURL: tool.url, logDirectory: logDirectory)
        await engine.run(inputs: inputs, recursive: recursive, operation: operation, cancellation: cancellation) {
            collector.record($0)
        }
        return collector.snapshot()
    }

    @discardableResult
    private func assertJob(
        _ job: RecordedJob, succeeded: Int = 0, skipped: Int = 0, failed: Int = 0, cancelled: Int = 0,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [PhotoItem] {
        let summary = try requireValue(job.summaries.first, "Missing finished event", file: file, line: line)
        expectEqual(job.summaries.count, 1, "Exactly one finished event", file: file, line: line)
        if case .finished? = job.events.last {} else { recordFailure("Finished must be the last event", file: file, line: line) }
        expectEqual(summary.total, succeeded + skipped + failed + cancelled, file: file, line: line)
        expectEqual(summary.succeeded, succeeded, file: file, line: line)
        expectEqual(summary.skipped, skipped, file: file, line: line)
        expectEqual(summary.failed, failed, file: file, line: line)
        expectEqual(summary.cancelled, cancelled, file: file, line: line)
        expectEqual(summary.total, summary.succeeded + summary.skipped + summary.failed + summary.cancelled,
                       "Every discovered item must have a terminal outcome", file: file, line: line)
        expectFalse(summary.message.isEmpty, file: file, line: line)

        let updates = job.updates
        let items = updates.map(\.item)
        expectEqual(job.discoveries.count, 1, file: file, line: line)
        expectEqual(job.discoveries.first?.map(\.id), items.map(\.id), file: file, line: line)
        expectEqual(items.count, summary.total, file: file, line: line)
        expectEqual(Set(items.map(\.id)).count, items.count, file: file, line: line)
        expectEqual(Set(items.map(\.url)).count, items.count, file: file, line: line)
        expectEqual(updates.map(\.completed), Array(0..<items.count).map { $0 + 1 }, file: file, line: line)
        expectTrue(updates.allSatisfy { $0.total == summary.total }, file: file, line: line)
        expectEqual(items.filter { $0.status == .success || $0.status == .ready }.count, summary.succeeded, file: file, line: line)
        expectEqual(items.filter { $0.status == .skipped }.count, summary.skipped, file: file, line: line)
        expectEqual(items.filter { $0.status == .failed }.count, summary.failed, file: file, line: line)
        expectEqual(items.filter { $0.status == .cancelled }.count, summary.cancelled, file: file, line: line)
        expectFalse(items.contains { $0.status == .pending }, file: file, line: line)

        let log = try requireValue(summary.logURL, "Expected a journal in the test sandbox", file: file, line: line)
        expectEqual(log.deletingLastPathComponent().standardizedFileURL, logDirectory.standardizedFileURL, file: file, line: line)
        let logData = try Data(contentsOf: log)
        expectEqual(logData.last, 0x0A, "The final journal record must be complete", file: file, line: line)
        let lines = logData.split(separator: 0x0A).map { Data($0) }
        expectEqual(lines.count, items.count + 2, "Header, one record per item, and summary", file: file, line: line)
        let header = try requireValue(JSONSerialization.jsonObject(with: requireValue(lines.first)) as? [String: Any], file: file, line: line)
        expectEqual(header["engine"] as? String, EngineResources.version, file: file, line: line)
        let journalItems = try lines.dropFirst().dropLast().map { try JSONDecoder().decode(PhotoItem.self, from: $0) }
        expectEqual(journalItems.map(\.id), items.map(\.id), file: file, line: line)
        expectEqual(journalItems.map(\.url), items.map(\.url), file: file, line: line)
        expectEqual(journalItems.map(\.status), items.map(\.status), file: file, line: line)
        let footer = try requireValue(JSONSerialization.jsonObject(with: requireValue(lines.last)) as? [String: Any], file: file, line: line)
        expectEqual(footer["summary"] as? String, summary.message, file: file, line: line)
        return items
    }

    private func assertOffsets(
        _ metadata: PhotoMetadata, original: String?, digitized: String?, time: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        expectEqual(metadata.offsetOriginal, original, file: file, line: line)
        expectEqual(metadata.offsetDigitized, digitized, file: file, line: line)
        expectEqual(metadata.offsetTime, time, file: file, line: line)
    }

    private func assertDates(_ metadata: PhotoMetadata, file: StaticString = #filePath, line: UInt = #line) {
        expectEqual(metadata.dateTimeOriginal, originalDate, file: file, line: line)
        expectEqual(metadata.createDate, createdDate, file: file, line: line)
        expectEqual(metadata.modifyDate, modifiedDate, file: file, line: line)
    }
}
