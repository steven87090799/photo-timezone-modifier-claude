import Foundation
import Testing
@testable import TimezoneCore

final class JPEGPayloadLayoutTests: TemporaryDirectoryTestCase {
    private func segment(_ marker: UInt8, _ payload: Data) -> Data {
        let length = payload.count + 2
        return Data([0xff, marker, UInt8(length >> 8), UInt8(length & 0xff)]) + payload
    }
    private var scan: Data {
        segment(0xda, Data([1, 1, 0, 0, 63, 0])) + Data([4, 5, 0xff, 0, 6, 0xff, 0xd0, 7, 0xff, 0xd9])
    }
    private func retained(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return try JPEGPayloadLayout.retainedRanges(in: url).reduce(into: Data()) { result, range in
            result.append(data[Int(range.start)..<Int(range.start + range.length)])
        }
    }

    @Test func excludesOnlyRecognizedMetadataAPP1AndRetainsAllOtherSegments() throws {
        let soi = Data([0xff, 0xd8])
        let app0 = segment(0xe0, Data("JFIF\0other header bytes".utf8))
        let exif = segment(0xe1, Data("Exif\0\0metadata may change".utf8))
        let xmp = segment(0xe1, Data("http://ns.adobe.com/xap/1.0/\0xmp document".utf8))
        let extendedXMP = segment(0xe1, Data("http://ns.adobe.com/xmp/extension/\0extended xmp".utf8))
        let unknownAPP1 = segment(0xe1, Data("Exif not an EXIF signature".utf8))
        let icc = segment(0xe2, Data("ICC_PROFILE\0color profile bytes".utf8))
        let comment = segment(0xfe, Data("irreplaceable comment".utf8))
        let table = segment(0xdb, Data([0, 1, 2, 3, 4]))
        let sof = segment(0xc0, Data([8, 0, 2, 0, 3, 1, 1, 0x11, 0]))
        let trailing = Data("private trailing bytes".utf8)
        let preserved = [soi, app0, unknownAPP1, icc, comment, table, sof, scan, trailing]
            .reduce(into: Data()) { $0.append($1) }
        let original = [soi, app0, exif, unknownAPP1, xmp, icc, extendedXMP, comment, table, sof, scan, trailing]
            .reduce(into: Data()) { $0.append($1) }
        let file = try makeFile("metadata.jpg", contents: original)
        #expect(try retained(file) == preserved)
    }

    @Test func progressiveTailPreservesLaterTablesScansAndTrailingBytes() throws {
        let first = segment(0xda, Data([1, 1, 0, 0, 0, 0])) + Data([8, 9, 0xff, 0, 10])
        let table = segment(0xc4, Data([0, 0xff, 0xd9, 1]))
        let second = segment(0xda, Data([1, 1, 0, 1, 63, 0])) + Data([11, 12, 0xff, 0xd9, 99])
        let bytes = Data([0xff, 0xd8]) + first + table + second
        let file = try makeFile("progressive.jpg", contents: bytes)
        #expect(try retained(file) == bytes)
    }

    @Test func truncatedSegmentsScansAndFalseEndMarkerInsidePayloadAreRejected() throws {
        let soi = Data([0xff, 0xd8])
        let firstScan = segment(0xda, Data([1, 1, 0, 0, 63, 0]))
        let invalidFiles: [Data] = [
            Data(), soi, soi + Data([0xff]), soi + Data([0xff, 0xe1, 0, 1]),
            soi + Data([0xff, 0xe1, 0, 12, 1, 2]), soi + Data([0xff, 0xd9]),
            soi + firstScan + Data([1, 2, 3]), soi + firstScan + Data([1, 0xff]),
            soi + firstScan + segment(0xc4, Data([0xff, 0xd9, 0])),
            soi + segment(0xda, Data([2, 1, 0, 0, 63, 0])) + Data([0xff, 0xd9])
        ]
        for (index, bytes) in invalidFiles.enumerated() {
            let file = try makeFile("truncated-\(index).jpg", contents: bytes)
            #expect(throws: (any Error).self) { _ = try JPEGPayloadLayout.retainedRanges(in: file) }
        }
    }

    @Test func actualGeneratedJPEGAndChunkBoundaryEntropyArePreserved() throws {
        let real = try makePhoto("real.jpg")
        let actual = try Data(contentsOf: real)
        let sos = try requireValue(actual.range(of: Data([0xff, 0xda])))
        #expect(try retained(real).suffix(actual.count - sos.lowerBound) == actual.suffix(actual.count - sos.lowerBound))
        let entropy = Data(repeating: 0x35, count: 64 * 1024 - 13) + Data([0xff, 0, 0xff, 0xd9])
        let bytes = Data([0xff, 0xd8]) + segment(0xda, Data([1, 1, 0, 0, 63, 0])) + entropy
        let large = try makeFile("chunk-boundary.jpg", contents: bytes)
        #expect(try retained(large) == bytes)
    }
}
