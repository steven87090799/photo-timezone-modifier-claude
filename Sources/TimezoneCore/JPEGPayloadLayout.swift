import Foundation

/// Byte ranges outside the EXIF/XMP APP1 containers that metadata writes may
/// legitimately change. Everything from the first scan through EOF is retained,
/// including progressive scans, ICC data and any trailing private bytes.
enum JPEGPayloadLayout {
    struct Range: Equatable {
        let start: UInt64
        let length: UInt64
    }

    private static let metadataSignatures = [
        Array("Exif\0\0".utf8),
        Array("http://ns.adobe.com/xap/1.0/\0".utf8),
        Array("http://ns.adobe.com/xmp/extension/\0".utf8)
    ]

    static func retainedRanges(in url: URL) throws -> [Range] {
        let identity = try FileIdentity.read(url)
        guard identity.size >= 4 else { throw invalid() }
        let reader = try Reader(url, size: UInt64(identity.size))
        guard try reader.byte(at: 0) == 0xff, try reader.byte(at: 1) == 0xd8 else { throw invalid() }
        var ranges = [Range(start: 0, length: 2)]
        var offset: UInt64 = 2
        var markers = 0
        while offset < reader.size {
            markers += 1
            guard markers <= 65_536 else { throw invalid() }
            let marker = try readMarker(reader, at: offset)
            guard marker.code != 0xd8, marker.code != 0xd9,
                  !(0xd0...0xd7).contains(marker.code) else { throw invalid() }
            if marker.code == 0x01 {
                append(Range(start: offset, length: marker.afterCode - offset), to: &ranges)
                offset = marker.afterCode
                continue
            }
            let segmentEnd = try endOfSegment(reader, afterCode: marker.afterCode)
            if marker.code == 0xda {
                try validateScanHeader(reader, afterCode: marker.afterCode, end: segmentEnd)
                try validateScanTail(reader, from: segmentEnd)
                append(Range(start: offset, length: reader.size - offset), to: &ranges)
                try identity.verify(url)
                return ranges
            }
            var excluded = false
            if marker.code == 0xe1 {
                let payloadStart = marker.afterCode + 2
                for signature in metadataSignatures where UInt64(signature.count) <= segmentEnd - payloadStart {
                    var matches = true
                    for (index, byte) in signature.enumerated() where try reader.byte(at: payloadStart + UInt64(index)) != byte {
                        matches = false
                        break
                    }
                    if matches { excluded = true; break }
                }
            }
            if !excluded { append(Range(start: offset, length: segmentEnd - offset), to: &ranges) }
            offset = segmentEnd
        }
        throw invalid()
    }

    private static func append(_ range: Range, to ranges: inout [Range]) {
        if let last = ranges.last, last.start + last.length == range.start {
            ranges[ranges.count - 1] = Range(start: last.start, length: last.length + range.length)
        } else {
            ranges.append(range)
        }
    }

    private static func readMarker(_ reader: Reader, at offset: UInt64) throws -> (code: UInt8, afterCode: UInt64) {
        guard try reader.byte(at: offset) == 0xff else { throw invalid() }
        var codeOffset = offset + 1
        while try reader.byte(at: codeOffset) == 0xff { codeOffset += 1 }
        let code = try reader.byte(at: codeOffset)
        guard code == 0x01 || (0xc0...0xfe).contains(code) else { throw invalid() }
        return (code, codeOffset + 1)
    }

    private static func endOfSegment(_ reader: Reader, afterCode: UInt64) throws -> UInt64 {
        guard afterCode <= reader.size, reader.size - afterCode >= 2 else { throw invalid() }
        let length = UInt64(try reader.byte(at: afterCode)) << 8 | UInt64(try reader.byte(at: afterCode + 1))
        guard length >= 2, length <= reader.size - afterCode else { throw invalid() }
        return afterCode + length
    }

    private static func validateScanHeader(_ reader: Reader, afterCode: UInt64, end: UInt64) throws {
        guard end - afterCode >= 6 else { throw invalid() }
        let components = UInt64(try reader.byte(at: afterCode + 2))
        guard components > 0, end - afterCode == 6 + 2 * components else { throw invalid() }
    }

    /// Scan markers without decoding pixels. Segment lengths are skipped rather
    /// than searching their payload for EOI, so an embedded FF D9 cannot mask a
    /// truncated progressive JPEG. These bytes remain one retained range.
    private static func validateScanTail(_ reader: Reader, from start: UInt64) throws {
        var offset = start
        while offset < reader.size {
            if try reader.byte(at: offset) != 0xff { offset += 1; continue }
            var codeOffset = offset + 1
            while try reader.byte(at: codeOffset) == 0xff { codeOffset += 1 }
            let code = try reader.byte(at: codeOffset)
            if code == 0x00 || code == 0x01 || (0xd0...0xd7).contains(code) {
                offset = codeOffset + 1
                continue
            }
            if code == 0xd9 { return }
            guard code != 0xd8, (0xc0...0xfe).contains(code) else { throw invalid() }
            let end = try endOfSegment(reader, afterCode: codeOffset + 1)
            if code == 0xda { try validateScanHeader(reader, afterCode: codeOffset + 1, end: end) }
            offset = end
        }
        throw invalid()
    }

    private static func invalid() -> PhotoError {
        PhotoError("JPEG 標記或影像掃描範圍不完整，無法逐位元組確認影像資料保留；未接受候選檔。")
    }

    private final class Reader {
        let size: UInt64
        private let handle: FileHandle
        private var buffer: [UInt8] = []
        private var bufferStart: UInt64 = 0

        init(_ url: URL, size: UInt64) throws {
            self.size = size
            handle = try FileHandle(forReadingFrom: url)
        }
        deinit { try? handle.close() }

        @inline(__always) func byte(at offset: UInt64) throws -> UInt8 {
            guard offset < size else { throw JPEGPayloadLayout.invalid() }
            if offset < bufferStart || offset - bufferStart >= UInt64(buffer.count) {
                try handle.seek(toOffset: offset)
                buffer = Array(try handle.read(upToCount: Int(min(64 * 1024, size - offset))) ?? Data())
                bufferStart = offset
            }
            guard offset - bufferStart < UInt64(buffer.count) else { throw JPEGPayloadLayout.invalid() }
            return buffer[Int(offset - bufferStart)]
        }
    }
}
