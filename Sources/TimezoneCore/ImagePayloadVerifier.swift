import Foundation
import CoreFoundation

/// Compare encoded image bytes without decoding, changing, or hashing them.
/// ExifTool exposes standard TIFF/EXIF offsets as absolute file offsets. Its
/// explicitly paired lengths identify thumbnails, previews, strips and tiles.
/// Undocumented private MakerNote containers are outside this byte certificate.
enum ImagePayloadVerifier {
    struct ByteRange: Equatable {
        let start: UInt64
        let length: UInt64
    }

    private static let pairs = ["StripOffsets": "StripByteCounts", "TileOffsets": "TileByteCounts",
        "ThumbnailOffset": "ThumbnailLength", "PreviewImageStart": "PreviewImageLength",
        "JpgFromRawStart": "JpgFromRawLength", "OtherImageStart": "OtherImageLength",
        "MPImageStart": "MPImageLength"]

    static func verify(source: URL, candidate: URL, before: ExifTool.Snapshot,
                       after: ExifTool.Snapshot, tool: ExifTool, cancellation: CancellationToken? = nil) throws {
        let sourceIdentity = try FileIdentity.read(source)
        let candidateIdentity = try FileIdentity.read(candidate)
        guard sourceIdentity.size >= 0, candidateIdentity.size >= 0,
              before.metadata.fileType == after.metadata.fileType else {
            throw PhotoError("影像格式或長度改變；候選檔已拒絕。")
        }
        let sourceSize = UInt64(sourceIdentity.size), candidateSize = UInt64(candidateIdentity.size)
        if before.metadata.fileType == "JPEG" {
            let left = try JPEGPayloadLayout.retainedRanges(in: source).map { ByteRange(start: $0.start, length: $0.length) }
            let right = try JPEGPayloadLayout.retainedRanges(in: candidate).map { ByteRange(start: $0.start, length: $0.length) }
            try compare(source, ranges: left, candidate, ranges: right, label: "JPEG 編碼與像素資料", cancellation: cancellation)
        }
        let sourceSpans = try spans(before.embeddedTags, limit: sourceSize)
        let candidateSpans = try spans(after.embeddedTags, limit: candidateSize)
        guard Set(sourceSpans.keys) == Set(candidateSpans.keys) else {
            throw PhotoError("影像 strip／tile／縮圖／預覽的區塊結構改變；候選檔已拒絕。")
        }
        if before.metadata.fileType != "JPEG" && !sourceSpans.contains(where: { key, ranges in
            ["StripOffsets", "TileOffsets"].contains(String(key.split(separator: ":").last ?? "")) &&
                ranges.contains { $0.length > 0 }
        }) {
            throw PhotoError("無法可靠識別 TIFF／RAW 的非空像素 strip／tile；未接受候選檔，原始照片保留。")
        }
        for key in sourceSpans.keys.sorted() {
            guard let left = sourceSpans[key], let right = candidateSpans[key],
                  left.map(\.length) == right.map(\.length) else {
                throw PhotoError("影像區塊長度改變：\(key)；候選檔已拒絕。")
            }
            try compare(source, ranges: left, candidate, ranges: right, label: key, cancellation: cancellation)
        }
        try verifyOpaquePreviews(source: source, candidate: candidate, before: before.embeddedTags,
            after: after.embeddedTags, knownSpans: Set(sourceSpans.keys), tool: tool, cancellation: cancellation)
        try sourceIdentity.verify(source)
        try candidateIdentity.verify(candidate)
    }

    /// Some MakerNotes (including Sony JPEG tag 0x2001) store an embedded image
    /// directly, without an exposed offset/length pair. Compare the complete
    /// extracted image bytes within ExifTool's existing 16 MiB output budget.
    private static func verifyOpaquePreviews(source: URL, candidate: URL, before: [String: String],
        after: [String: String], knownSpans: Set<String>, tool: ExifTool,
        cancellation: CancellationToken?) throws {
        let imageOffsets = ["ThumbnailImage": "ThumbnailOffset", "PreviewImage": "PreviewImageStart",
            "PreviewImageData": "PreviewImageStart", "JpgFromRaw": "JpgFromRawStart", "OtherImage": "OtherImageStart"]
        for key in before.keys.sorted() {
            let parts = key.split(separator: ":")
            guard let name = parts.last.map(String.init),
                  let offset = imageOffsets[name], let summary = before[key],
                  summary.contains("(Binary data ") else { continue }
            let prefix = parts.dropLast().joined(separator: ":") + ":"
            if knownSpans.contains(prefix + offset) { continue }
            guard after[key] == summary else { throw PhotoError("內嵌預覽欄位改變：\(key)；候選檔已拒絕。") }
            let first = try tool.execute(["-charset", "filename=UTF8", "-b", "-\(key)", source.path],
                timeout: 120, cancellation: cancellation)
            let second = try tool.execute(["-charset", "filename=UTF8", "-b", "-\(key)", candidate.path],
                timeout: 120, cancellation: cancellation)
            guard first.status == 0, second.status == 0,
                  !first.stdout.isEmpty || summary.contains("(Binary data 0 bytes"),
                  first.stdout == second.stdout else {
                throw PhotoError("內嵌預覽的完整影像資料不符或無法讀出：\(key)；候選檔已拒絕。")
            }
        }
    }

    private static func spans(_ tags: [String: String], limit: UInt64) throws -> [String: [ByteRange]] {
        var result: [String: [ByteRange]] = [:]
        for key in tags.keys.sorted() {
            let parts = key.split(separator: ":")
            guard let name = parts.last.map(String.init), let lengthName = pairs[name],
                  let group = parts.first, !group.hasPrefix("XMP"),
                  group != "ICC_Profile", group != "IPTC" else { continue }
            let prefix = parts.dropLast().joined(separator: ":") + ":"
            guard let offsetText = tags[key], let lengthText = tags[prefix + lengthName],
                  let offsets = numbers(offsetText), let lengths = numbers(lengthText),
                  !offsets.isEmpty, offsets.count == lengths.count else {
                throw PhotoError("無法可靠解析影像區塊位置與長度：\(key)；候選檔已拒絕。")
            }
            result[key] = try zip(offsets, lengths).map { offset, length in
                guard offset <= limit, length <= limit - offset else {
                    throw PhotoError("影像區塊超出檔案範圍：\(key)；候選檔已拒絕。")
                }
                return ByteRange(start: offset, length: length)
            }
        }
        return result
    }

    private static func numbers(_ canonical: String) -> [UInt64]? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(canonical.utf8), options: [.fragmentsAllowed]) else { return nil }
        func unsigned(_ value: Any) -> UInt64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return UInt64(number.stringValue)
        }
        if let number = unsigned(value) { return [number] }
        if let array = value as? [Any] {
            let parsed = array.compactMap(unsigned)
            return parsed.count == array.count ? parsed : nil
        }
        guard let text = value as? String else { return nil }
        let components = text.split { $0.isWhitespace || $0 == "," }
        let parsed = components.compactMap { UInt64($0) }
        return !parsed.isEmpty && parsed.count == components.count ? parsed : nil
    }

    /// Read at most 1 MiB per side. Segment boundaries may move when metadata
    /// changes, so compare the retained byte streams rather than file offsets.
    static func compare(_ source: URL, ranges left: [ByteRange], _ candidate: URL,
                        ranges right: [ByteRange], label: String,
                        cancellation: CancellationToken? = nil) throws {
        func total(_ ranges: [ByteRange]) throws -> UInt64 {
            try ranges.reduce(0) { sum, range in
                let (value, overflow) = sum.addingReportingOverflow(range.length)
                guard !overflow else { throw PhotoError("影像區塊長度溢位；候選檔已拒絕。") }
                return value
            }
        }
        guard try total(left) == total(right) else {
            throw PhotoError("\(label) 的編碼資料長度改變；候選檔已拒絕。")
        }
        let lhs = try FileHandle(forReadingFrom: source), rhs = try FileHandle(forReadingFrom: candidate)
        defer { try? lhs.close(); try? rhs.close() }
        var li = 0, ri = 0
        var lo: UInt64 = 0, ro: UInt64 = 0
        while li < left.count && ri < right.count {
            if cancellation?.isCancelled == true { throw CancellationError() }
            if lo == left[li].length { li += 1; lo = 0; continue }
            if ro == right[ri].length { ri += 1; ro = 0; continue }
            let count = Int(min(1024 * 1024, left[li].length - lo, right[ri].length - ro))
            try lhs.seek(toOffset: left[li].start + lo)
            try rhs.seek(toOffset: right[ri].start + ro)
            let a = try lhs.read(upToCount: count) ?? Data(), b = try rhs.read(upToCount: count) ?? Data()
            guard a.count == count, b.count == count, a == b else {
                throw PhotoError("\(label) 的影像／縮圖／預覽內容改變或無法完整讀取；候選檔已拒絕，原始照片保留。")
            }
            lo += UInt64(count); ro += UInt64(count)
        }
    }
}
