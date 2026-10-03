import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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

    private func thumbnailBytes(_ file: URL) throws -> Data {
        let output = try tool.execute(["-m", "-b", "-ThumbnailImage", file.path], timeout: 120)
        guard output.status == 0, !output.stdout.isEmpty else {
            throw PhotoError("Test fixture has no readable EXIF thumbnail. \(output.text)")
        }
        return output.stdout
    }

    @Test func testAppAndCoreAlwaysUseThreeOffsetsWithMetadataCompatibility() {
        expectEqual(WriteOptions.appDefault.sonyCompatibility, true)
        // Verification strictness remains configurable, but the write target
        // is fixed to all three standard EXIF offset fields.
        expectEqual(WriteOptions(sonyCompatibility: false).sonyCompatibility, false)
    }

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
        // Match production transport, but do not launch an external process
        // from suite initialization. Swift Testing may instantiate suites while
        // discovering filtered tests; eager ExifTool I/O here can stall the
        // entire runner before the first test starts.
        tool = ExifTool(url: url, persistent: true)
        logDirectory = temporaryDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    @Test func testPinnedExifToolVersionAndPersistentTransportStarts() throws {
        try tool.validateVersion()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"] != nil))
    func testRealSonyA7IVARWTimezoneGPSBackupAndRestore() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"] else { return }
        let fixture = URL(fileURLWithPath: path)
        try FileSafety.ensureRegular(fixture)
        let photo = temporaryDirectory.appendingPathComponent("ILCE-7M4-real.ARW")
        try FileManager.default.copyItem(at: fixture, to: photo)

        let originalDigest = try digest(of: photo)
        let before = try tool.snapshot(photo)
        expectEqual(before.metadata.fileType, "ARW")
        expectTrue(before.metadata.make?.uppercased() == "SONY")
        expectTrue(before.metadata.cameraModel?.contains("ILCE-7M4") == true)
        let originalDates = before.metadata.dateTags
        let imageHash = try tool.imageDataSHA256(photo)

        _ = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 345), mode: .replaceAll,
            options: WriteOptions(sonyCompatibility: true)
        )), succeeded: 1)
        let timezoneResult = try tool.snapshot(photo)
        expectEqual(timezoneResult.metadata.dateTags, originalDates)
        assertOffsets(timezoneResult.metadata, original: "+05:45", digitized: "+05:45", time: "+05:45")
        expectEqual(try tool.imageDataSHA256(photo), imageHash)
        expectEqual(try digest(of: originalBackup(for: photo)), originalDigest)

        _ = try assertJob(await run([photo], operation: .restore), succeeded: 1)
        expectEqual(try digest(of: photo), originalDigest)

        let restored = try tool.snapshot(photo)
        expectEqual(restored.metadata.dateTags, originalDates)
        expectFalse(restored.metadata.hasAnyGPS)
        let restoredOffsets = (restored.metadata.offsetOriginal, restored.metadata.offsetDigitized, restored.metadata.offsetTime)
        _ = try assertJob(await run([photo], operation: .addGPS(
            location: GPSCoordinate(latitude: 25.0330, longitude: 121.5654, altitudeMeters: 12.5),
            options: WriteOptions(sonyCompatibility: true)
        )), succeeded: 1)
        let gpsResult = try tool.snapshot(photo)
        expectEqual(gpsResult.metadata.dateTags, originalDates)
        expectEqual(gpsResult.metadata.offsetOriginal, restoredOffsets.0)
        expectEqual(gpsResult.metadata.offsetDigitized, restoredOffsets.1)
        expectEqual(gpsResult.metadata.offsetTime, restoredOffsets.2)
        expectTrue(gpsResult.metadata.hasCompleteGPSCoordinate)
        expectEqual(try tool.imageDataSHA256(photo), imageHash)
    }

    @Test func testImportantExifPreviewFieldsAreReadFromStandardTags() throws {
        let photo = try makeSeededPhoto("important-exif-preview.jpg")
        let output = try tool.execute([
            "-overwrite_original",
            "-EXIF:Make=Preview Camera Co.",
            "-EXIF:Model=Preview Body 1",
            "-EXIF:SerialNumber=BODY-123",
            "-EXIF:LensMake=Preview Lens Co.",
            "-EXIF:LensModel=35mm Test Lens",
            "-EXIF:LensSerialNumber=LENS-456",
            "-EXIF:SubSecTimeOriginal=123",
            "-EXIF:SubSecTimeDigitized=456",
            "-EXIF:SubSecTime=789",
            "-EXIF:ISO=200",
            "-EXIF:ExposureTime=1/125",
            "-EXIF:FNumber=2.8",
            "-EXIF:ExposureProgram#=1",
            "-EXIF:ExposureCompensation=-0.7",
            "-EXIF:MeteringMode#=5",
            "-EXIF:Flash#=0",
            "-EXIF:FocalLength=35",
            "-EXIF:FocalLengthIn35mmFormat=35",
            "-EXIF:WhiteBalance#=0",
            "-EXIF:SceneCaptureType#=0",
            "-EXIF:Orientation#=1",
            "-EXIF:ColorSpace#=1",
            "-EXIF:Software=PhotoTimezone Preview Test",
            "-GPSLatitude#=25.03", "-GPSLatitudeRef=N",
            "-GPSLongitude#=121.56", "-GPSLongitudeRef=E",
            "-GPSAltitude#=10", "-GPSAltitudeRef#=0",
            "-GPSDateStamp=2026:10:01", "-GPSTimeStamp=06:30:00",
            photo.path
        ], timeout: 120)
        expectEqual(output.status, 0)

        let metadata = try tool.inspect(photo).0
        expectEqual(metadata.make, "Preview Camera Co.")
        expectEqual(metadata.cameraModel, "Preview Body 1")
        expectEqual(metadata.bodySerialNumber, "BODY-123")
        expectEqual(metadata.cameraSerialNumber, "BODY-123")
        expectEqual(metadata.lensMake, "Preview Lens Co.")
        expectEqual(metadata.lensModel, "35mm Test Lens")
        expectEqual(metadata.lensModelSource, "ExifIFD:LensModel")
        expectEqual(metadata.lensSerialNumber, "LENS-456")
        expectEqual(metadata.subSecTimeOriginal, "123")
        expectEqual(metadata.subSecTimeDigitized, "456")
        expectEqual(metadata.subSecTime, "789")
        expectEqual(metadata.software, "PhotoTimezone Preview Test")
        expectTrue(metadata.iso != nil)
        expectTrue(metadata.exposureTime != nil)
        expectTrue(metadata.aperture != nil)
        expectTrue(metadata.exposureProgram != nil)
        expectTrue(metadata.exposureCompensation != nil)
        expectTrue(metadata.meteringMode != nil)
        expectTrue(metadata.flash != nil)
        expectTrue(metadata.focalLength != nil)
        expectTrue(metadata.focalLength35mm != nil)
        expectTrue(metadata.whiteBalance != nil)
        expectTrue(metadata.sceneCaptureType != nil)
        expectTrue(metadata.orientation != nil)
        expectTrue(metadata.colorSpace != nil)
        expectTrue(metadata.mimeType != nil)
        expectTrue(metadata.gpsLatitude != nil)
        expectTrue(metadata.gpsLongitude != nil)
        expectTrue(metadata.gpsAltitude != nil)
        expectTrue(metadata.gpsDateStamp != nil)
        expectTrue(metadata.gpsTimeStamp != nil)
    }

    @Test func testManualGPSSafetyBundle() async throws {
        try await verifyManualGPSAdditionPreservesDatesOffsetsAndCreatesBackup()
        try await verifyManualGPSCopyLeavesSourceUntouched()
        try await verifyManualGPSNeverOverwritesExistingOrSidecarGPS()
    }

    @Test func testReviewGPSRejectsPartialXMPAndUnreadableSidecarState() async throws {
        let location = try GPSCoordinate(latitude: 25.033, longitude: 121.5654)
        // Direction/speed without latitude or longitude are still existing GPS.
        let embedded = try makeSeededPhoto("review-embedded.jpg")
        expectEqual(try tool.execute(["-overwrite_original", "-XMP-exif:GPSImgDirection=123.5", embedded.path]).status, 0)
        let exifPartial = try makeSeededPhoto("review-exif-partial.jpg")
        expectEqual(try tool.execute(["-overwrite_original", "-EXIF:GPSSpeed=0", exifPartial.path]).status, 0)
        let structured = try makeSeededPhoto("review-structured.jpg")
        expectEqual(try tool.execute(["-overwrite_original", "-XMP-iptcExt:LocationShownGPSLatitude=25.033", structured.path]).status, 0)
        let sidecarPhoto = try makeSeededPhoto("REVIEW-SIDECAR.jpg")
        let sidecar = try makeFile("review-sidecar.xmp", contents: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSSpeed="0"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let sidecarBytes = try Data(contentsOf: sidecar)
        for photo in [embedded, exifPartial, structured, sidecarPhoto] {
            let bytes = try Data(contentsOf: photo)
            let preview = try assertJob(await run([photo], operation: .inspect), succeeded: 1)
            expectTrue(preview[0].metadata?.hasAnyGPS == true)
            expectFalse(preview[0].metadata?.canSafelyAddGPS == true)
            _ = try assertJob(await run([photo], operation: .addGPS(location: location)), skipped: 1)
            expectEqual(try Data(contentsOf: photo), bytes)
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
        }
        expectEqual(try Data(contentsOf: sidecar), sidecarBytes)

        // A renamed JPEG can yield successful empty selected-tag JSON. That
        // does not establish the absence of GPS in a readable XMP sidecar.
        let unknown = try makeSeededPhoto("review-wrong-sidecar-type.jpg")
        let unknownBytes = try Data(contentsOf: unknown)
        _ = try makeFile("review-wrong-sidecar-type.xmp", contents: unknownBytes)
        let preview = try assertJob(await run([unknown], operation: .inspect), succeeded: 1)
        expectTrue(preview[0].metadata?.gpsSafetyUncertain == true)
        _ = try assertJob(await run([unknown], operation: .addGPS(location: location)), skipped: 1)
        expectEqual(try Data(contentsOf: unknown), unknownBytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: unknown).path))
    }

    @Test func testPR3ReviewLinkedXMPCannotBypassGPSSafety() async throws {
        let photo = try makeSeededPhoto("linked-gps.jpg")
        let originalBytes = try Data(contentsOf: photo)
        let target = try makeFile("external-gps.xmp", contents: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSLatitude="25,1.98N"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let sidecarBytes = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: photo.deletingPathExtension().appendingPathExtension("xmp"),
            withDestinationURL: target)
        _ = try assertJob(await run([photo], operation: .addGPS(
            location: GPSCoordinate(latitude: 35, longitude: 139))), failed: 1)
        expectEqual(try Data(contentsOf: photo), originalBytes)
        expectEqual(try Data(contentsOf: target), sidecarBytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testReviewRescanRefreshesChangedFileIdentity() async throws {
        let photo = try makeSeededPhoto("review-rescan.jpg")
        let old = try FileIdentity.read(photo)
        expectEqual(try tool.execute(["-overwrite_original", "-EXIF:ISO=400", photo.path]).status, 0)
        let bytes = try Data(contentsOf: photo)
        let collector = JobEventCollector()
        await PhotoEngine(exiftoolURL: tool.url, logDirectory: logDirectory).run(
            inputs: [photo], recursive: false, operation: .inspect, cancellation: CancellationToken(),
            expectedIdentities: [photo.path: old]) { collector.record($0) }
        let preview = try assertJob(collector.snapshot(), succeeded: 1)
        expectEqual(preview[0].sourceIdentity, try FileIdentity.read(photo))
        expectEqual(preview[0].metadata?.iso, "400")
        expectEqual(try Data(contentsOf: photo), bytes)
    }

    private func verifyManualGPSAdditionPreservesDatesOffsetsAndCreatesBackup() async throws {
        let photo = try makeSeededPhoto("manual-gps-bundle-original.jpg", original: "+08:00", digitized: "+08:00", time: "+08:00")
        let originalBytes = try Data(contentsOf: photo)
        let location = try GPSCoordinate(latitude: 25.033, longitude: 121.5654, altitudeMeters: 12.5)

        let rows = try assertJob(await run([photo], operation: .addGPS(location: location)), succeeded: 1)
        let metadata = try tool.snapshot(photo).metadata
        assertDates(metadata)
        assertOffsets(metadata, original: "+08:00", digitized: "+08:00", time: "+08:00")
        expectTrue(metadata.hasCompleteGPSCoordinate)
        expectEqual(metadata.gpsLatitudeRef, "N")
        expectEqual(metadata.gpsLongitudeRef, "E")
        expectEqual(try Data(contentsOf: originalBackup(for: photo)), originalBytes)
        expectEqual(rows[0].status, .success)
        expectTrue(rows[0].detail.contains("GPS"))
    }

    private func verifyManualGPSCopyLeavesSourceUntouched() async throws {
        let photo = try makeSeededPhoto("manual-gps-bundle-copy.jpg", original: "+05:45", digitized: "+05:45", time: "+05:45")
        let sourceBytes = try Data(contentsOf: photo)
        let output = try makeDirectory("manual-gps-bundle-copy-output")
        let location = try GPSCoordinate(latitude: -33.8688, longitude: 151.2093, altitudeMeters: nil)

        let rows = try assertJob(await run([photo], operation: .addGPSCopy(
            location: location, destination: output, sourceRoots: [photo]
        )), succeeded: 1)

        expectEqual(try Data(contentsOf: photo), sourceBytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
        let copy = output.appendingPathComponent(photo.lastPathComponent)
        let metadata = try tool.snapshot(copy).metadata
        assertDates(metadata)
        assertOffsets(metadata, original: "+05:45", digitized: "+05:45", time: "+05:45")
        expectTrue(metadata.hasCompleteGPSCoordinate)
        expectEqual(metadata.gpsLatitudeRef, "S")
        expectEqual(metadata.gpsLongitudeRef, "E")
        expectEqual(rows[0].outputURL, copy)
    }

    private func verifyManualGPSNeverOverwritesExistingOrSidecarGPS() async throws {
        let existing = try makeSeededPhoto("manual-gps-bundle-existing.jpg")
        expectEqual(try tool.execute([
            "-overwrite_original", "-GPSLatitude#=25.03", "-GPSLatitudeRef=N",
            "-GPSLongitude#=121.56", "-GPSLongitudeRef=E", existing.path
        ]).status, 0)
        let existingBytes = try Data(contentsOf: existing)
        let location = try GPSCoordinate(latitude: 35.0, longitude: 139.0)
        _ = try assertJob(await run([existing], operation: .addGPS(location: location)), skipped: 1)
        expectEqual(try Data(contentsOf: existing), existingBytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: existing).path))

        _ = try makeDirectory("manual-gps-bundle-sidecar")
        let sidecarPhoto = try makeSeededPhoto("manual-gps-bundle-sidecar/photo.jpg")
        let sidecar = try makeFile("manual-gps-bundle-sidecar/photo.xmp", contents: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSLatitude="25,1.98N" exif:GPSLongitude="121,33.6E"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let photoBytes = try Data(contentsOf: sidecarPhoto)
        let sidecarBytes = try Data(contentsOf: sidecar)
        _ = try assertJob(await run([sidecarPhoto], operation: .addGPS(location: location)), skipped: 1)
        expectEqual(try Data(contentsOf: sidecarPhoto), photoBytes)
        expectEqual(try Data(contentsOf: sidecar), sidecarBytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: sidecarPhoto).path))

        // If an XMP sidecar is too large to inspect within the bounded
        // diagnostic budget, GPS absence is unknown. Fail closed rather than
        // assuming it is safe to add a conflicting EXIF location.
        _ = try makeDirectory("manual-gps-bundle-unknown-sidecar")
        let unknownPhoto = try makeSeededPhoto("manual-gps-bundle-unknown-sidecar/photo.jpg")
        let unknownBytes = try Data(contentsOf: unknownPhoto)
        _ = try makeFile(
            "manual-gps-bundle-unknown-sidecar/photo.xmp",
            contents: Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)
        )
        let unknown = try assertJob(await run([unknownPhoto], operation: .addGPS(location: location)), skipped: 1)
        expectEqual(try Data(contentsOf: unknownPhoto), unknownBytes)
        expectTrue(unknown[0].metadata?.gpsSafetyUncertain == true)
        expectTrue(unknown[0].detail.contains("無法可靠確認"))
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: unknownPhoto).path))
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

    @Test func testCopyAlwaysFillsAllThreeStandardOffsetsWithoutShiftingDates() async throws {
        let photo = try makeSeededPhoto("all-three.jpg")
        let original = try Data(contentsOf: photo)
        let output = try makeDirectory("all-three-output")
        let rows = try assertJob(await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output,
            sourceRoots: [photo]
        )), succeeded: 1)
        let candidate = output.appendingPathComponent(photo.lastPathComponent)
        let metadata = try tool.inspect(candidate).0
        assertOffsets(metadata, original: "+08:00", digitized: "+08:00", time: "+08:00")
        assertDates(metadata)
        expectEqual(try Data(contentsOf: photo), original)
        expectEqual(rows[0].outputURL, candidate)
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
        _ = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 480), mode: .replaceAll
        )), succeeded: 1)
        let backup = originalBackup(for: photo)
        expectEqual(try Data(contentsOf: backup), original)
        try FileManager.default.removeItem(at: photo)
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
        _ = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 480), mode: .replaceAll
        )), succeeded: 1)
        let backup = originalBackup(for: photo)
        try FileManager.default.removeItem(at: photo)
        let restored = await run([backup], operation: .restore)
        let items = try assertJob(restored, succeeded: 1)
        expectEqual(items[0].url.path, photo.path)
        expectEqual(try Data(contentsOf: photo), original)
    }

    @Test func testPreexistingValidOriginalWithoutProvenanceIsNeverTrusted() async throws {
        let photo = try makeSeededPhoto("foreign-backup.jpg")
        let sourceBytes = try Data(contentsOf: photo)
        let unrelated = try makeSeededPhoto("unrelated.jpg", original: "+01:00")
        let foreignBytes = try Data(contentsOf: unrelated)
        let backup = originalBackup(for: photo)
        try foreignBytes.write(to: backup)

        let write = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 480), mode: .replaceAll
        )), failed: 1)
        expectTrue(write[0].detail.contains("provenance"))
        expectEqual(try Data(contentsOf: photo), sourceBytes)
        expectEqual(try Data(contentsOf: backup), foreignBytes)

        let restore = try assertJob(await run([photo], operation: .restore), failed: 1)
        expectTrue(restore[0].detail.contains("provenance"))
        expectEqual(try Data(contentsOf: photo), sourceBytes)
        expectEqual(try Data(contentsOf: backup), foreignBytes)
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
        let setup = try tool.execute(["-overwrite_original", "-Make=SONY", "-Model=ILCE-7M4", "-SerialNumber=TEST-12345",
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
        expectEqual(before.cameraSerialNumber, "TEST-12345")
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
        expectEqual(after.cameraSerialNumber, before.cameraSerialNumber)
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

    @Test func testSonyJPEGStrictRejectsMakerNotesButCompatiblePreservesThumbnailBytes() async throws {
        let sample = tool.url.deletingLastPathComponent().appendingPathComponent("t/images/Sony.jpg")
        let original = try Data(contentsOf: sample)
        let photo = try makeFile("camera-thumb.jpg", contents: original)
        let thumbnail = try thumbnailBytes(photo)
        expectTrue(!thumbnail.isEmpty)
        let output = try makeDirectory("output")
        let copy = output.appendingPathComponent(photo.lastPathComponent)
        let rejected = try assertJob(await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [photo],
            options: WriteOptions(sonyCompatibility: false)
        )), failed: 1)
        expectTrue(rejected[0].detail.contains("metadata") || rejected[0].detail.contains("ThumbnailOffset"))
        expectFalse(FileManager.default.fileExists(atPath: copy.path))
        expectEqual(try Data(contentsOf: photo), original)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
        let copied = try assertJob(await run([photo], operation: .writeCopy(
            offset: UTCOffset(minutes: 480), mode: .fillMissing, destination: output, sourceRoots: [photo],
            options: WriteOptions(sonyCompatibility: true)
        )), succeeded: 1)
        expectEqual(copied[0].outputURL, copy)
        expectEqual(try Data(contentsOf: photo), original)
        expectEqual(try thumbnailBytes(copy), thumbnail)
        assertOffsets(try tool.inspect(copy).0, original: "+08:00", digitized: "+08:00", time: "+08:00")

        _ = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 480), mode: .fillMissing,
            options: WriteOptions(sonyCompatibility: true)
        )), succeeded: 1)
        expectEqual(try Data(contentsOf: originalBackup(for: photo)), original)
        expectEqual(try thumbnailBytes(photo), thumbnail)
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

    @Test func testRestoreByteVerificationDetectsSameSizeMutation() throws {
        let original = try makeFile("restore-byte-source.bin", contents: Data([0, 1, 2, 3, 4, 5]))
        let candidate = try makeFile("restore-byte-candidate.bin", contents: Data([0, 1, 2, 3, 4, 5]))
        expectTrue(try SafeFileTransaction.contentsAreIdentical(original, candidate))

        try Data([0, 1, 9, 3, 4, 5]).write(to: candidate)
        expectFalse(try SafeFileTransaction.contentsAreIdentical(original, candidate))
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
        let unexpected = written.updates.map(\.item).filter { $0.status == .failed && $0.url != bad }
        if !unexpected.isEmpty { print("STRESS_WRITE_FAILURES", unexpected.map { "\($0.url.lastPathComponent): \($0.detail)" }) }
        try #require(unexpected.isEmpty, "First-pass failures are not hidden by retries")
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
        try #require(failures.isEmpty, "Every copy must succeed on the first pass")
        let initialRows = try assertJob(copied, succeeded: 1000, failed: 0)
        let finalRows = Dictionary(uniqueKeysWithValues: initialRows.map { ($0.url.path, $0) })
        for (index, source) in photos.enumerated() {
            expectEqual(try Data(contentsOf: source), original)
            expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: source).path))
            let copy = output.appendingPathComponent("copy-thousand/day\(index / 100)/DSC\(index).jpg")
            let row = try requireValue(finalRows[source.path])
            expectEqual(row.outputURL, copy)
            assertOffsets(try requireValue(row.outputMetadata), original: "+08:00", digitized: "+08:00", time: "+08:00")
            expectTrue(FileManager.default.fileExists(atPath: copy.path))
        }
        print("STRESS_COPY_RESULT photos=1000 copy_seconds=\(Date().timeIntervalSince(started)) sources_unchanged=1000 first_pass_failures=\(failures.count) retried=0")
    }

    @Test func testSubsecondsAndEveryDateSurviveThreeOffsetWrites() async throws {
        let photo = try makeSeededPhoto("fractions.jpg", original: "+09:00", digitized: "-03:30", time: "+00:00")
        let seed = try tool.execute(["-overwrite_original", "-SubSecTimeOriginal=001200", "-SubSecTimeDigitized=0001", "-SubSecTime=999", photo.path])
        expectEqual(seed.status, 0)
        let before = try tool.snapshot(photo)
        let bytes = try Data(contentsOf: photo)
        _ = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 345), mode: .replaceAll)), succeeded: 1)
        let after = try tool.snapshot(photo)
        expectEqual(before.metadata.dateTags, after.metadata.dateTags)
        assertOffsets(after.metadata, original: "+05:45", digitized: "+05:45", time: "+05:45")
        expectEqual(try Data(contentsOf: originalBackup(for: photo)), bytes)
    }

    @Test func testNumericSnapshotRejectsSubDisplayGPSMutation() throws {
        let photo = try makeSeededPhoto("gps.jpg")
        expectEqual(try tool.execute(["-overwrite_original", "-GPSLatitude#=25.03", "-GPSLatitudeRef=N", photo.path]).status, 0)
        let before = try tool.snapshot(photo)
        expectEqual(try tool.execute(["-overwrite_original", "-GPSLatitude#=25.0300001", photo.path]).status, 0)
        let after = try tool.snapshot(photo)
        let key = try requireValue(before.embeddedTags.keys.first { $0.hasSuffix(":GPSLatitude") })
        expectNotEqual(before.embeddedTags[key], after.embeddedTags[key])
        #expect(throws: PhotoError.self) {
            try MetadataVerifier.verify(before: before, after: after, assignments: [], options: WriteOptions())
        }
    }

    @Test func testSonySR2StructuralSpanRelocationIsBoundedAndCompatibilityGated() throws {
        var beforeMetadata = PhotoMetadata(
            dateTimeOriginal: originalDate,
            offsetOriginal: "+02:00",
            offsetDigitized: "+02:00",
            offsetTime: "+02:00",
            fileType: "ARW",
            createDate: createdDate,
            modifyDate: modifiedDate,
            dateTags: ["ExifIFD:DateTimeOriginal": originalDate]
        )
        beforeMetadata.make = "SONY"
        beforeMetadata.fileSize = 100_000

        var afterMetadata = beforeMetadata
        afterMetadata.fileSize = 101_000

        let beforeTags = [
            "SR2:SR2SubIFDOffset": "1000",
            "SR2:SR2SubIFDLength": "2000",
            "SR2:SR2SubIFDKey": "12345",
            "IFD2:JpgFromRawStart": "5000",
            "Sony:HiddenDataOffset": "8000",
            "Sony:HiddenDataLength": "1000",
            "SubIFD:TileOffsets": "[10000,20000]"
        ]
        let afterTags = [
            "SR2:SR2SubIFDOffset": "1200",
            "SR2:SR2SubIFDLength": "2100",
            "SR2:SR2SubIFDKey": "12345",
            "IFD2:JpgFromRawStart": "5200",
            "Sony:HiddenDataOffset": "8300",
            "Sony:HiddenDataLength": "1100",
            "SubIFD:TileOffsets": "[10200,20200]"
        ]
        let before = ExifTool.Snapshot(metadata: beforeMetadata, warnings: "", embeddedTags: beforeTags)
        let after = ExifTool.Snapshot(metadata: afterMetadata, warnings: "", embeddedTags: afterTags)

        let notices = try MetadataVerifier.verify(
            before: before, after: after, assignments: [],
            options: WriteOptions(sonyCompatibility: true)
        )
        expectTrue(notices.contains { $0.contains("SR2:SR2SubIFDLength") })
        expectTrue(notices.contains { $0.contains("IFD2:JpgFromRawStart") })
        expectTrue(notices.contains { $0.contains("Sony:HiddenDataOffset") })
        expectTrue(notices.contains { $0.contains("Sony:HiddenDataLength") })
        expectTrue(notices.contains { $0.contains("SubIFD:TileOffsets") })

        #expect(throws: PhotoError.self) {
            try MetadataVerifier.verify(
                before: before, after: after, assignments: [],
                options: WriteOptions(sonyCompatibility: false)
            )
        }

        var invalidTags = afterTags
        invalidTags["SR2:SR2SubIFDLength"] = "200000"
        let invalid = ExifTool.Snapshot(metadata: afterMetadata, warnings: "", embeddedTags: invalidTags)
        #expect(throws: PhotoError.self) {
            try MetadataVerifier.verify(
                before: before, after: invalid, assignments: [],
                options: WriteOptions(sonyCompatibility: true)
            )
        }

        var invalidHiddenTags = afterTags
        invalidHiddenTags["Sony:HiddenDataLength"] = "200000"
        let invalidHidden = ExifTool.Snapshot(metadata: afterMetadata, warnings: "", embeddedTags: invalidHiddenTags)
        #expect(throws: PhotoError.self) {
            try MetadataVerifier.verify(
                before: before, after: invalidHidden, assignments: [],
                options: WriteOptions(sonyCompatibility: true)
            )
        }
    }

    @Test func testConflictingXMPBlocksFillMissingAndNeverRewrites() async throws {
        let photo = try makeSeededPhoto("conflict.jpg")
        expectEqual(try tool.execute(["-overwrite_original", "-XMP-exif:DateTimeOriginal=\(originalDate)+09:00", photo.path]).status, 0)
        let before = try tool.snapshot(photo)
        let rows = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing)), failed: 1)
        let after = try tool.snapshot(photo)
        expectEqual(after.embeddedTags, before.embeddedTags)
        expectTrue(rows[0].detail.contains("時區衝突"))
        assertDates(after.metadata)
        _ = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 480), mode: .replaceAll)), succeeded: 1)
        let overwritten = try tool.snapshot(photo)
        expectTrue(overwritten.embeddedTags.contains { key, value in
            key.hasPrefix("XMP-exif:") && key.hasSuffix(":DateTimeOriginal") &&
                value.contains("06:07:08+08:00")
        })
    }

    @Test func testEmbeddedXMPMissingOffsetIsFilledWithoutChangingClock() async throws {
        let photo = try makeSeededPhoto("embedded-date.jpg")
        expectEqual(try tool.execute(["-overwrite_original",
            "-XMP-exif:DateTimeOriginal=2021-04-05T06:07:08", photo.path]).status, 0)
        _ = try assertJob(await run([photo], operation: .write(
            offset: UTCOffset(minutes: 480), mode: .fillMissing)), succeeded: 1)
        let after = try tool.snapshot(photo)
        assertOffsets(after.metadata, original: "+08:00", digitized: "+08:00", time: "+08:00")
        let xmpDates = after.embeddedTags.filter {
            $0.key.hasPrefix("XMP-exif:") && $0.key.hasSuffix(":DateTimeOriginal")
        }
        expectTrue(xmpDates.values.allSatisfy { $0.contains("06:07:08+08:00") })
        expectTrue(!xmpDates.isEmpty)
    }

    @Test func testBatchGPSAndExistingXMPSidecarCommitTogether() async throws {
        let photo = try makeSeededPhoto("xmp-bundle/photo.jpg")
        let sidecar = try makeFile("xmp-bundle/photo.xmp", contents: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:DateTimeOriginal="2021-04-05T06:07:08"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let photoBytes = try Data(contentsOf: photo)
        let sidecarBytes = try Data(contentsOf: sidecar)
        let output = try makeDirectory("xmp-bundle-output")
        let gps = try GPSCoordinate(latitude: 25.033, longitude: 121.5654)
        let options = WriteOptions(gps: GPSWriteRequest(coordinate: gps, overwrite: false))
        _ = try assertJob(await run([photo], operation: .writeCopy(offset: UTCOffset(minutes: 480),
            mode: .fillMissing, destination: output, sourceRoots: [photo.deletingLastPathComponent()],
            options: options)), succeeded: 1)
        let copy = output.appendingPathComponent("xmp-bundle/photo.jpg")
        let xmpCopy = output.appendingPathComponent("xmp-bundle/photo.xmp")
        let metadata = try tool.inspect(copy).0
        assertOffsets(metadata, original: "+08:00", digitized: "+08:00", time: "+08:00")
        expectTrue(metadata.hasCompleteGPSCoordinate)
        let xmp = try tool.readSidecar(xmpCopy)
        expectTrue(xmp.hasGPS)
        expectTrue(xmp.dates["XMP-exif:DateTimeOriginal"]?.hasSuffix("+08:00") == true)
        expectEqual(try Data(contentsOf: photo), photoBytes)
        expectEqual(try Data(contentsOf: sidecar), sidecarBytes)
    }

    @Test func testGPSOverwriteSynchronizesEXIFEmbeddedXMPAndSidecar() async throws {
        let photo = try makeSeededPhoto("gps-overwrite/photo.jpg")
        let seeded = try tool.execute([
            "-overwrite_original",
            "-GPS:GPSLatitude=35", "-GPS:GPSLatitudeRef=N",
            "-GPS:GPSLongitude=139", "-GPS:GPSLongitudeRef=E",
            "-XMP-exif:GPSLatitude=35", "-XMP-exif:GPSLongitude=139",
            "-XMP-dc:Description=Keep this edit", photo.path
        ])
        expectEqual(seeded.status, 0)
        let sidecar = try makeFile("gps-overwrite/photo.xmp", contents: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" exif:GPSLatitude="35" exif:GPSLongitude="139" dc:description="Keep sidecar edit"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let originalPhoto = try Data(contentsOf: photo)
        let originalSidecar = try Data(contentsOf: sidecar)
        let output = try makeDirectory("gps-overwrite-output")
        let newLocation = try GPSCoordinate(latitude: -33.8688, longitude: 151.2093,
            altitudeMeters: -12.5)
        let options = WriteOptions(gps: GPSWriteRequest(coordinate: newLocation, overwrite: true),
            timezonePaths: [])
        _ = try assertJob(await run([photo], operation: .writeCopy(offset: UTCOffset(minutes: 480),
            mode: .fillMissing, destination: output, sourceRoots: [photo.deletingLastPathComponent()],
            options: options)), succeeded: 1)
        let copy = output.appendingPathComponent("gps-overwrite/photo.jpg")
        let xmpCopy = output.appendingPathComponent("gps-overwrite/photo.xmp")
        let metadata = try tool.inspect(copy).0
        expectTrue(metadata.hasCompleteGPSCoordinate)
        let embedded = try tool.snapshot(copy).embeddedTags
        try MetadataVerifier.verifyXMPCoordinate(tags: embedded, coordinate: newLocation)
        let sidecarTags = try tool.readSidecar(xmpCopy).tags
        try MetadataVerifier.verifyXMPCoordinate(tags: sidecarTags, coordinate: newLocation)
        expectEqual(embedded["XMP-dc:Description"], try tool.snapshot(photo).embeddedTags["XMP-dc:Description"])
        expectEqual(sidecarTags["XMP-dc:Description"], try tool.readSidecar(sidecar).tags["XMP-dc:Description"])
        expectEqual(try Data(contentsOf: photo), originalPhoto)
        expectEqual(try Data(contentsOf: sidecar), originalSidecar)
    }

    @Test func testSharedXMPSidecarFailsBeforePublishingEitherPhoto() async throws {
        let root = try makeDirectory("sidecars")
        let first = try makeSeededPhoto("sidecars/shared.jpg")
        let second = try makeSeededPhoto("sidecars/shared.tiff", format: .tiff)
        let xmp = try makeFile("sidecars/shared.xmp", contents: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:DateTimeOriginal="2021-04-05T06:07:08+09:00"/></rdf:RDF></x:xmpmeta>
        """.utf8))
        let on1 = try makeFile("sidecars/shared.on1", contents: Data("{\"edits\":\"preserve bytes\"}".utf8))
        let originals = try [first, second, xmp, on1].map { try Data(contentsOf: $0) }
        let output = try makeDirectory("sidecar-output")
        let rows = try assertJob(await run([first, second], operation: .writeCopy(offset: UTCOffset(minutes: 480), mode: .fillMissing,
            destination: output, sourceRoots: [root])), failed: 2)
        for (url, bytes) in zip([first, second, xmp, on1], originals) { expectEqual(try Data(contentsOf: url), bytes) }
        expectFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("sidecars/shared.jpg").path))
        expectFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("sidecars/shared.tiff").path))
        expectTrue(rows.allSatisfy { $0.detail.contains("共用同一個 XMP sidecar") })
    }

    @Test func testSidecarCollisionDoesNotPublishThePhoto() async throws {
        let root = try makeDirectory("input-sidecar")
        let photo = try makeSeededPhoto("input-sidecar/photo.jpg")
        _ = try makeFile("input-sidecar/photo.on1", contents: Data("source sidecar".utf8))
        let original = try Data(contentsOf: photo)
        let output = try makeDirectory("output-sidecar")
        let occupied = try makeFile("output-sidecar/input-sidecar/photo.on1", contents: Data("existing edits".utf8))
        _ = try assertJob(await run([photo], operation: .writeCopy(offset: UTCOffset(minutes: 480), mode: .fillMissing,
            destination: output, sourceRoots: [root])), failed: 1)
        expectFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("input-sidecar/photo.jpg").path))
        expectEqual(try Data(contentsOf: occupied), Data("existing edits".utf8))
        expectEqual(try Data(contentsOf: photo), original)
    }

    @Test func testInspectedIdentityRejectsAReplacementAtTheSamePath() async throws {
        let photo = try makeSeededPhoto("identity.jpg")
        let preview = try assertJob(await run([photo], operation: .inspect), succeeded: 1)
        let identity = try requireValue(preview[0].sourceIdentity)
        let bytes = try Data(contentsOf: photo)
        try FileManager.default.removeItem(at: photo)
        try bytes.write(to: photo)
        let collector = JobEventCollector()
        await PhotoEngine(exiftoolURL: tool.url, logDirectory: logDirectory).run(inputs: [photo], recursive: false,
            operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing), cancellation: CancellationToken(),
            inspectedFilesOnly: true, expectedIdentities: [photo.path: identity]) { collector.record($0) }
        _ = try assertJob(collector.snapshot(), failed: 1)
        expectEqual(try Data(contentsOf: photo), bytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testExtremeInvalidOffsetDoesNotCrashOrChangePhoto() async throws {
        let photo = try makeSeededPhoto("invalid-offset.jpg")
        let bytes = try Data(contentsOf: photo)
        let job = await run([photo], operation: .write(offset: UTCOffset(minutes: Int.min), mode: .replaceAll))
        expectEqual(job.summaries.first?.failed, 1)
        expectEqual(try Data(contentsOf: photo), bytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testMissingAssociatedDatesAreNotInvented() async throws {
        let photo = try makeSeededPhoto("missing-dates.jpg")
        expectEqual(try tool.execute(["-overwrite_original", "-EXIF:CreateDate=", "-EXIF:ModifyDate=", photo.path]).status, 0)
        _ = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing)), succeeded: 1)
        let after = try tool.inspect(photo).0
        expectEqual(after.dateTimeOriginal, originalDate)
        expectEqual(after.createDate, nil)
        expectEqual(after.modifyDate, nil)
        assertOffsets(after, original: "+08:00", digitized: "+08:00", time: "+08:00")
    }

    @Test func testInvalidCalendarDateIsNotSilentlyRepaired() async throws {
        let photo = try makeSeededPhoto("bad-date.jpg")
        expectEqual(try tool.execute(["-overwrite_original", "-DateTimeOriginal#=0000:00:00 00:00:00", photo.path]).status, 0)
        let bytes = try Data(contentsOf: photo)
        _ = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing)), failed: 1)
        expectEqual(try Data(contentsOf: photo), bytes)
        expectFalse(FileManager.default.fileExists(atPath: originalBackup(for: photo).path))
    }

    @Test func testRecoveryBeforePublicationArchivesOnlyTheManifest() throws {
        let photo = try makeSeededPhoto("not-published.jpg")
        let bytes = try Data(contentsOf: photo)
        let stage = SafeFileTransaction.temporaryPhoto(beside: photo)
        try SafeFileTransaction.copyAndSync(photo, to: stage)
        let identity = try FileIdentity.read(photo)
        let manifest = TransactionManifest(version: 1, id: UUID(), source: photo, target: photo, candidate: stage,
            backup: nil, sourceIdentity: identity, targetIdentityBefore: identity, candidateIdentity: try FileIdentity.read(stage),
            originalDates: [:], oldOffsets: [:], newOffsets: [:], sidecarTargets: [], publishedSidecars: [], phase: .prepared, detail: "test")
        let store = try TransactionStore(directory: logDirectory.appendingPathComponent("Transactions"))
        try store.save(manifest)
        expectTrue(try store.unfinished().isEmpty)
        expectEqual(try Data(contentsOf: photo), bytes)
        expectFalse(FileManager.default.fileExists(atPath: stage.path))
        expectTrue(FileManager.default.fileExists(atPath: store.history.appendingPathComponent("\(manifest.id).json").path))
    }

    @Test func testStorageMaintenanceKeepsPhotoBackupsAndProvenanceButRemovesSafeClutter() throws {
        let photo = try makeSeededPhoto("storage.jpg")
        let backup = originalBackup(for: photo)
        try SafeFileTransaction.copyAndSync(photo, to: backup)

        let support = try makeDirectory("storage-support")
        let logs = support.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: logs.appendingPathComponent("job-test.jsonl"))

        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions"))
        let sourceIdentity = try FileIdentity.read(photo)
        let provenanceID = UUID()
        let protectedRecord = TransactionManifest(
            version: 2, id: provenanceID, source: photo, target: photo,
            candidate: temporaryDirectory.appendingPathComponent("consumed-candidate.jpg"),
            backup: backup, sourceIdentity: sourceIdentity, targetIdentityBefore: sourceIdentity,
            candidateIdentity: nil, canonicalBackupIdentity: try FileIdentity.read(backup),
            originalDates: [:], oldOffsets: [:], newOffsets: [:],
            sidecarTargets: [], publishedSidecars: [], phase: .committed, detail: "provenance"
        )
        try store.finish(protectedRecord)

        let disposableRecord = TransactionManifest(
            version: 2, id: UUID(), source: photo, target: photo,
            candidate: temporaryDirectory.appendingPathComponent("consumed-other.jpg"),
            backup: nil, sourceIdentity: sourceIdentity, targetIdentityBefore: sourceIdentity,
            candidateIdentity: nil, originalDates: [:], oldOffsets: [:], newOffsets: [:],
            sidecarTargets: [], publishedSidecars: [], phase: .committed, detail: "removable"
        )
        try store.finish(disposableRecord)

        let orphan = photo.deletingLastPathComponent()
            .appendingPathComponent(".photo-timezone-\(UUID().uuidString).jpg")
        try SafeFileTransaction.copyCandidate(photo, to: orphan)

        let before = try StorageMaintenance.snapshot(photoURLs: [photo], support: support)
        expectTrue(before.photoBackups >= 1)
        expectTrue(before.orphanCandidates >= 1)
        expectTrue(before.historyFiles >= 2)
        expectTrue(before.logFiles >= 1)

        let admin = try StorageMaintenance.cleanAdministrativeHistory(support: support)
        expectTrue(admin.removedFiles >= 2)
        expectTrue(FileManager.default.fileExists(atPath: backup.path))
        expectTrue(FileManager.default.fileExists(
            atPath: store.history.appendingPathComponent("\(provenanceID.uuidString).json").path
        ))

        let candidates = try StorageMaintenance.cleanOrphanCandidates(photoURLs: [photo], support: support)
        expectTrue(candidates.removedFiles >= 1)
        expectFalse(FileManager.default.fileExists(atPath: orphan.path))
        expectTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func testRecoveryAfterRenameBlocksAutomaticRetry() async throws {
        let photo = try makeSeededPhoto("published.jpg")
        let backup = originalBackup(for: photo)
        try SafeFileTransaction.copyAndSync(photo, to: backup)
        let stage = SafeFileTransaction.temporaryPhoto(beside: photo)
        try SafeFileTransaction.copyCandidate(photo, to: stage)
        expectEqual(try tool.execute(["-overwrite_original_in_place", "-OffsetTimeOriginal=+09:00", stage.path]).status, 0)
        try SafeFileTransaction.syncFile(stage)
        let identity = try FileIdentity.read(photo)
        let manifest = TransactionManifest(version: 1, id: UUID(), source: photo, target: photo, candidate: stage,
            backup: backup, sourceIdentity: identity, targetIdentityBefore: identity, candidateIdentity: try FileIdentity.read(stage),
            originalDates: [:], oldOffsets: [:], newOffsets: [:], sidecarTargets: [], publishedSidecars: [], phase: .prepared, detail: "test")
        let store = try TransactionStore(directory: logDirectory.appendingPathComponent("Transactions"))
        try store.save(manifest)
        try SafeFileTransaction.replace(stage, at: photo)
        let publishedBytes = try Data(contentsOf: photo)
        let pending = try store.unfinished()
        expectEqual(pending.count, 1)
        expectEqual(pending.first?.phase, .publicationUnconfirmed)
        let rows = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .replaceAll)), failed: 1)
        expectTrue(rows[0].publicationUnconfirmed)
        expectEqual(try Data(contentsOf: photo), publishedBytes)
        expectTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func testHardlinksAreDeduplicatedAndOriginalReplacementRejected() async throws {
        let photo = try makeSeededPhoto("hard.jpg")
        let alias = temporaryDirectory.appendingPathComponent("hard-alias.jpg")
        try FileManager.default.linkItem(at: photo, to: alias)
        let original = try Data(contentsOf: photo)
        let found = FileDiscovery.collect(inputs: [photo, alias], recursive: false, cancellation: CancellationToken())
        expectEqual(found.count, 1)
        _ = try assertJob(await run([photo], operation: .write(offset: UTCOffset(minutes: 480), mode: .fillMissing)), failed: 1)
        let output = try makeDirectory("hard-copy")
        _ = try assertJob(await run([photo], operation: .writeCopy(offset: UTCOffset(minutes: 480), mode: .fillMissing,
            destination: output, sourceRoots: [photo])), succeeded: 1)
        expectEqual(try Data(contentsOf: photo), original)
        expectEqual(try Data(contentsOf: alias), original)
    }

    @Test func testSessionFramesErrorsAndRestartsWithoutStaleOutput() throws {
        let persistent = ExifTool(url: tool.url, persistent: true)
        for _ in 0..<132 {
            let response = try persistent.execute(["-ver"], timeout: 5)
            expectEqual(response.status, 0)
            expectTrue(response.stderr.isEmpty, "Worker startup must not leak locale warnings into a photo snapshot.")
            expectEqual(String(decoding: response.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), EngineResources.version)
        }
        let error = try persistent.execute([temporaryDirectory.appendingPathComponent("absent.jpg").path], timeout: 5)
        expectNotEqual(error.status, 0)
        expectEqual(try persistent.execute(["-ver"], timeout: 5).status, 0)
        let unusual = try makeSeededPhoto("new\nline.jpg")
        expectEqual(try persistent.inspect(unusual).0.dateTimeOriginal, originalDate)
        expectEqual(try persistent.execute(["-ver"], timeout: 5).status, 0)
    }

    @Test func testSessionTimeoutAndOversizedOutputFailClosed() throws {
        let hanging = try makeFile("hanging.pl", contents: Data("sleep 30;\n".utf8))
        let worker = ExifTool(url: hanging, persistent: true)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: PhotoError.self) { try worker.execute(["-ver"], timeout: 0.1) }
        expectTrue(ProcessInfo.processInfo.systemUptime - start < 4)
        let flood = try makeFile("flood.pl", contents: Data("print 'x' x (17 * 1024 * 1024);\n".utf8))
        #expect(throws: PhotoError.self) { try ExifTool(url: flood).execute([], timeout: 5) }
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
        let terminalDetails = job.updates.map {
            "\($0.item.url.lastPathComponent): \($0.item.status.rawValue) — \($0.item.detail)"
        }.joined(separator: " | ")
        expectEqual(summary.total, succeeded + skipped + failed + cancelled, terminalDetails, file: file, line: line)
        expectEqual(summary.succeeded, succeeded, terminalDetails, file: file, line: line)
        expectEqual(summary.skipped, skipped, terminalDetails, file: file, line: line)
        expectEqual(summary.failed, failed, terminalDetails, file: file, line: line)
        expectEqual(summary.cancelled, cancelled, terminalDetails, file: file, line: line)
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
