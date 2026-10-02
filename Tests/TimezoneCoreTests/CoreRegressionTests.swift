import Foundation
import Testing
@testable import TimezoneCore

@Suite(.serialized)
struct CoreRegressionTests {
    @Test func testReviewUnknownGPSSafetySurvivesJournalRoundTrip() throws {
        var metadata = PhotoMetadata(dateTimeOriginal: nil, offsetOriginal: nil, offsetDigitized: nil,
            offsetTime: nil, fileType: "JPEG", createDate: nil, modifyDate: nil, dateTags: [:])
        metadata.gpsSafetyUncertain = true
        let decoded = try JSONDecoder().decode(PhotoMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded.gpsSafetyUncertain)
        #expect(!decoded.canSafelyAddGPS)
        metadata.gpsSafetyUncertain = false
        metadata.embeddedEXIFGPSDetected = true
        let partial = try JSONDecoder().decode(PhotoMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(partial.hasEmbeddedEXIFGPS)
        #expect(!partial.canSafelyAddGPS)
    }

    @Test func legacyJournalRowsDecodeWithoutNewFields() throws {
        let item = PhotoItem(url: URL(fileURLWithPath: "/tmp/legacy.jpg"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object.removeValue(forKey: "publicationUnconfirmed")
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.id == item.id)
        #expect(!decoded.publicationUnconfirmed)
        let metadata = PhotoMetadata(dateTimeOriginal: "2021:04:05 06:07:08", offsetOriginal: nil,
            offsetDigitized: nil, offsetTime: nil, fileType: "JPEG", createDate: nil, modifyDate: nil, dateTags: [:])
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        old.removeValue(forKey: "compatibilityIssues")
        old.removeValue(forKey: "gpsSafetyUncertain")
        old.removeValue(forKey: "embeddedEXIFGPSDetected")
        let read = try JSONDecoder().decode(PhotoMetadata.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(read.compatibilityIssues.isEmpty)
        #expect(!read.gpsSafetyUncertain)
        #expect(!read.embeddedEXIFGPSDetected)
        #expect(read.dateTimeOriginal == metadata.dateTimeOriginal)
    }

    @Test func extremeOffsetsFormatWithoutIntegerOverflow() {
        for value in [Int.min, Int.max, -721, 841, 1] {
            let offset = UTCOffset(minutes: value)
            #expect(!offset.isValid)
            #expect(!offset.value.isEmpty)
        }
        #expect(UTCOffset(minutes: -210).value == "-03:30")
        #expect(UTCOffset(minutes: 345).value == "+05:45")
    }

    @Test func strictCalendarAndOffsetValidation() {
        #expect(TimeValidation.isCaptureDate("2024:02:29 23:59:59"))
        for date in ["2023:02:29 01:00:00", "0000:00:00 00:00:00", "2024:01:01 24:00:00", "2024:01:01", "2024-01-01T00:00:00"] {
            #expect(!TimeValidation.isCaptureDate(date))
        }
        for offset in ["+00:00", "-00:00", "+14:00", "-03:30", "+05:45", "+12:34"] {
            #expect(TimeValidation.isOffset(offset))
        }
        for offset in ["", "UTC+8", "+8:00", "-12:01", "-13:00", "-14:00", "+14:01", "+08:60", " 08:00", "+08:00 "] {
            #expect(!TimeValidation.isOffset(offset))
        }
    }

    @Test func defaultScopeAndRetryAreConsistent() {
        #expect(WriteOptions().sonyCompatibility == WriteOptions.appDefault.sonyCompatibility)
        #expect(WriteOptions().copySidecars == WriteOptions.appDefault.copySidecars)
        var item = PhotoItem(url: URL(fileURLWithPath: "/test.jpg"), status: .failed)
        item.publicationUnconfirmed = true
        #expect(!PhotoFilter.unfinished.matches(item))
        #expect(PhotoFilter.failed.matches(item))
        item.publicationUnconfirmed = false
        #expect(PhotoFilter.unfinished.matches(item))
    }

    @Test func boundedEventsDeliverEveryResultInOrder() async {
        let channel = BoundedJobEvents(capacity: 3)
        let producer = Task.detached {
            for number in 0..<1000 { channel.send(.phase(String(number))) }
            channel.finish()
        }
        var values: [Int] = []
        for await event in channel.events {
            channel.acknowledge()
            if case .phase(let text) = event, let number = Int(text) { values.append(number) }
        }
        await producer.value
        #expect(values == Array(0..<1000))
    }

    @Test func closedChannelReleasesBlockedProducer() async throws {
        let channel = BoundedJobEvents(capacity: 1)
        let producer = Task.detached {
            for _ in 0..<20 { channel.send(.phase("progress")) }
            channel.finish()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        channel.close()
        await producer.value
    }

    @Test func progressOnlyChangesReuseNaturalSort() async {
        let index = CatalogueIndex()
        var items = (0..<2000).reversed().map { PhotoItem(url: URL(fileURLWithPath: "/photos/DSC\($0).jpg")) }
        let first = await index.project(items, query: "", filter: .all, camera: nil, sort: .filename)
        #expect(first.rows.first?.url.lastPathComponent == "DSC0.jpg")
        #expect(first.rows.last?.url.lastPathComponent == "DSC1999.jpg")
        #expect(await index.sortPasses == 1)
        for i in items.indices { items[i].status = .success }
        let second = await index.project(items, query: "", filter: .success, camera: nil, sort: .filename)
        #expect(second.rows.count == items.count)
        #expect(await index.sortPasses == 1)
        let filtered = await index.project(items, query: "DSC99", filter: .all, camera: nil, sort: .filename)
        #expect(!filtered.rows.isEmpty)
        #expect(await index.sortPasses == 1)
        #expect(PhotoCatalogue.page(second.rows, index: 0).count == 200)
    }

    @Test func metadataOnlyPolicyRejectsArbitraryTagChanges() throws {
        var metadata = PhotoMetadata(dateTimeOriginal: "2024:02:29 12:34:56", offsetOriginal: nil,
            offsetDigitized: nil, offsetTime: nil, fileType: "JPEG", createDate: nil, modifyDate: nil, dateTags: [:])
        metadata.fileSize = 20000
        let before = ExifTool.Snapshot(metadata: metadata, warnings: "", embeddedTags: ["ExifIFD:ISO": "100"])
        let after = ExifTool.Snapshot(metadata: metadata, warnings: "", embeddedTags: ["ExifIFD:ISO": "200"])
        #expect(throws: PhotoError.self) {
            try MetadataVerifier.verify(before: before, after: after, assignments: [], options: WriteOptions())
        }
        let warned = ExifTool.Snapshot(metadata: metadata, warnings: "new parser warning", embeddedTags: before.embeddedTags)
        #expect(throws: PhotoError.self) {
            try MetadataVerifier.verify(before: before, after: warned, assignments: [], options: WriteOptions())
        }
        let source = ExifTool.Snapshot(metadata: metadata, warnings: "", embeddedTags: ["IFD1:ThumbnailOffset": "120"])
        for pointer in ["true", "1.5", "-1", "20000", "[1,20000]"] {
            let altered = ExifTool.Snapshot(metadata: metadata, warnings: "", embeddedTags: ["IFD1:ThumbnailOffset": pointer])
            #expect(throws: PhotoError.self) {
                try MetadataVerifier.verify(before: source, after: altered, assignments: [], options: WriteOptions())
            }
        }
    }

    @Test func gpsCoordinateValidationAndFormatting() throws {
        let taipei = try GPSCoordinate.parse(latitude: "25.0330", longitude: "121.5654", altitude: "12.5")
        #expect(taipei.latitude == 25.033)
        #expect(taipei.longitude == 121.5654)
        #expect(taipei.altitudeMeters == 12.5)
        #expect(taipei.latitudeRef == "N")
        #expect(taipei.longitudeRef == "E")
        #expect(taipei.altitudeRef == "0")
        #expect(taipei.latitudeArgument == "25.033")
        #expect(taipei.longitudeArgument == "121.5654")

        let southern = try GPSCoordinate(latitude: -33.8688, longitude: -70.6693, altitudeMeters: -15)
        #expect(southern.latitudeRef == "S")
        #expect(southern.longitudeRef == "W")
        #expect(southern.altitudeRef == "1")

        #expect(throws: PhotoError.self) {
            try GPSCoordinate.parse(latitude: "91", longitude: "121", altitude: "")
        }
        #expect(throws: PhotoError.self) {
            try GPSCoordinate.parse(latitude: "25", longitude: "181", altitude: "")
        }
        #expect(throws: PhotoError.self) {
            try GPSCoordinate.parse(latitude: "abc", longitude: "121", altitude: "")
        }
    }

    @Test func partialOrExternalGPSCountsAsExistingMetadata() {
        var metadata = PhotoMetadata(dateTimeOriginal: nil, offsetOriginal: nil, offsetDigitized: nil,
            offsetTime: nil, fileType: "JPEG", createDate: nil, modifyDate: nil, dateTags: [:])
        #expect(!metadata.hasAnyGPS)
        metadata.gpsLatitude = "25.03"
        #expect(metadata.hasAnyGPS)
        #expect(!metadata.hasCompleteGPSCoordinate)
        metadata.gpsLongitude = "121.56"
        #expect(metadata.hasCompleteGPSCoordinate)

        var xmpOnly = PhotoMetadata(dateTimeOriginal: nil, offsetOriginal: nil, offsetDigitized: nil,
            offsetTime: nil, fileType: "JPEG", createDate: nil, modifyDate: nil, dateTags: [:])
        xmpOnly.embeddedXMPGPSDetected = true
        #expect(xmpOnly.hasAnyGPS)

        var sidecarOnly = PhotoMetadata(dateTimeOriginal: nil, offsetOriginal: nil, offsetDigitized: nil,
            offsetTime: nil, fileType: "JPEG", createDate: nil, modifyDate: nil, dateTags: [:])
        sidecarOnly.sidecarGPSDetected = true
        #expect(sidecarOnly.hasAnyGPS)
    }

    @Test func xmpISOFormattingDoesNotInventAClockConflict() {
        let metadata = PhotoMetadata(dateTimeOriginal: "2024:02:29 12:34:56", offsetOriginal: "+08:00",
            offsetDigitized: "+08:00", offsetTime: "+08:00", fileType: "JPEG",
            createDate: "2024:02:29 12:34:56", modifyDate: "2024:02:29 12:34:56", dateTags: [:])
        let same = TimeValidation.issues(metadata, dates: ["XMP-exif:DateTimeOriginal": "2024-02-29T12:34:56+08:00"])
        #expect(same.isEmpty)
        let different = TimeValidation.issues(metadata, dates: ["XMP-exif:DateTimeOriginal": "2024-02-29T12:34:56+09:00"])
        #expect(different.contains { $0.contains("conflict") })

        let inconsistent = PhotoMetadata(
            dateTimeOriginal: "2024:02:29 12:34:56", offsetOriginal: "+08:00",
            offsetDigitized: "+09:00", offsetTime: "+08:00", fileType: "JPEG",
            createDate: "2024:02:29 12:34:56", modifyDate: "2024:02:29 12:34:56", dateTags: [:]
        )
        #expect(TimeValidation.issues(inconsistent).contains { $0.contains("inconsistent") })
    }
}
