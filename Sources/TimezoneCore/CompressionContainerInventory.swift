import Foundation

/// A readable-tag inventory cannot see every container payload. Refuse opaque
/// source blocks that the conversion pipeline has no defined way to preserve.
enum CompressionContainerInventory {
    static func validate(_ source: URL) throws {
        let identity = try FileIdentity.read(source)
        guard identity.size >= 0, identity.size <= 256 * 1024 * 1024 else {
            throw PhotoError("來源超出可安全核對的容器大小，未接受轉檔。")
        }
        let reader = try Reader(source, size: UInt64(identity.size))
        if reader.size >= 8, try reader.matches(Array([137, 80, 78, 71, 13, 10, 26, 10]), at: 0) {
            try validatePNG(reader)
        } else if reader.size >= 2, try reader.byte(0) == 0xff, try reader.byte(1) == 0xd8 {
            try validateJPEG(reader)
        }
        try identity.verify(source)
    }

    private static func validatePNG(_ reader: Reader) throws {
        let known: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "cHRM", "gAMA", "iCCP", "sBIT",
            "sRGB", "cICP", "bKGD", "hIST", "tRNS", "pHYs", "sPLT", "tIME", "iTXt", "tEXt", "zTXt", "eXIf"]
        let keywords: Set<String> = ["Title", "Author", "Description", "Copyright", "Creation Time", "Software",
            "Disclaimer", "Warning", "Source", "Comment", "XML:com.adobe.xmp", "Raw profile type exif",
            "Raw profile type iptc", "Raw profile type xmp"]
        var offset: UInt64 = 8, chunks = 0
        var sawHeader = false, sawImage = false
        while offset < reader.size {
            chunks += 1
            guard chunks <= 100_000, reader.size - offset >= 12 else { throw invalid("PNG 區塊結構") }
            let length = try reader.uint32(offset)
            guard length <= reader.size - offset - 12 else { throw invalid("PNG 區塊長度") }
            let type = try reader.text(offset + 4, count: 4)
            guard known.contains(type) else { throw invalid("PNG 附加區塊 \(type)") }
            if !sawHeader {
                guard type == "IHDR", length == 13 else { throw invalid("PNG IHDR") }
                sawHeader = true
            } else if type == "IHDR" { throw invalid("重複 PNG IHDR") }
            if type == "IDAT" { sawImage = true }
            if type == "cICP" {
                guard length == 4, [1, 12].contains(try reader.byte(offset + 8)),
                      try reader.byte(offset + 9) == 13, try reader.byte(offset + 10) == 0,
                      try reader.byte(offset + 11) == 1 else {
                    throw invalid("PNG cICP HDR 或非標準 RGB 色彩宣告")
                }
            }
            if ["iTXt", "tEXt", "zTXt"].contains(type) {
                let start = offset + 8
                var bytes: [UInt8] = []
                while UInt64(bytes.count) < length, bytes.count <= 79 {
                    let byte = try reader.byte(start + UInt64(bytes.count))
                    if byte == 0 { break }
                    bytes.append(byte)
                }
                guard !bytes.isEmpty, bytes.count <= 79, UInt64(bytes.count) < length,
                      try reader.byte(start + UInt64(bytes.count)) == 0,
                      let keyword = String(bytes: bytes, encoding: .isoLatin1), keywords.contains(keyword) else {
                    throw invalid("PNG 未支援的文字欄位")
                }
            }
            offset += length + 12
            if type == "IEND" {
                guard length == 0, sawImage, offset == reader.size else { throw invalid("PNG 尾端資料") }
                return
            }
        }
        throw invalid("PNG 缺少 IEND")
    }

    private static func validateJPEG(_ reader: Reader) throws {
        var offset: UInt64 = 2, inScan = false, sawScan = false, markers = 0
        while offset < reader.size {
            if try inScan && reader.byte(offset) != 0xff { offset += 1; continue }
            guard try reader.byte(offset) == 0xff else { throw invalid("JPEG 標記") }
            var codeOffset = offset + 1
            while try reader.byte(codeOffset) == 0xff { codeOffset += 1 }
            let code = try reader.byte(codeOffset)
            if inScan && (code == 0x00 || code == 0x01 || (0xd0...0xd7).contains(code)) {
                offset = codeOffset + 1; continue
            }
            markers += 1
            guard markers <= 65_536 else { throw invalid("JPEG 標記數量") }
            if code == 0xd9 {
                guard sawScan, codeOffset + 1 == reader.size else { throw invalid("JPEG 尾附資料") }
                return
            }
            guard code != 0xd8, (0xc0...0xfe).contains(code), reader.size - codeOffset >= 3 else {
                throw invalid("JPEG 標記結構")
            }
            let length = UInt64(try reader.byte(codeOffset + 1)) << 8 | UInt64(try reader.byte(codeOffset + 2))
            guard length >= 2, length <= reader.size - codeOffset - 1 else { throw invalid("JPEG 區塊長度") }
            let payload = codeOffset + 3, end = codeOffset + 1 + length
            if (0xe0...0xef).contains(code) {
                guard !sawScan else { throw invalid("JPEG 掃描後附加區塊") }
                switch code {
                case 0xe0:
                    guard try reader.matches(Array("JFIF\0".utf8), at: payload, end: end), end - payload == 14,
                          try reader.byte(payload + 12) == 0, try reader.byte(payload + 13) == 0 else {
                        throw invalid("JPEG JFIF 縮圖或擴充資料")
                    }
                case 0xe1:
                    let signatures = ["Exif\0\0", "http://ns.adobe.com/xap/1.0/\0", "http://ns.adobe.com/xmp/extension/\0"]
                    var recognized = false
                    for signature in signatures where try reader.matches(Array(signature.utf8), at: payload, end: end) { recognized = true }
                    guard recognized else { throw invalid("JPEG APP1 私有資料") }
                case 0xe2:
                    guard try reader.matches(Array("ICC_PROFILE\0".utf8), at: payload, end: end), end - payload >= 14 else {
                        throw invalid("JPEG APP2 非 ICC 資料")
                    }
                case 0xed:
                    try validatePhotoshop(reader, start: payload, end: end)
                case 0xee:
                    guard end - payload == 12, try reader.matches(Array("Adobe".utf8), at: payload, end: end) else {
                        throw invalid("JPEG APP14 私有資料")
                    }
                default: throw invalid("JPEG APP\(code - 0xe0) 私有資料")
                }
            }
            if code == 0xda { sawScan = true; inScan = true }
            offset = end
        }
        throw invalid("JPEG 缺少 EOI")
    }

    private static func validatePhotoshop(_ reader: Reader, start: UInt64, end: UInt64) throws {
        let signature = Array("Photoshop 3.0\0".utf8)
        guard try reader.matches(signature, at: start, end: end) else { throw invalid("JPEG APP13 私有資料") }
        // These resources have a preservation path with byte/field checks.
        let supported: Set<UInt64> = [0x03ed, 0x0404, 0x0409, 0x040c, 0x040f, 0x0424, 0x0425]
        var offset = start + UInt64(signature.count)
        while offset < end {
            guard end - offset >= 12, try reader.matches(Array("8BIM".utf8), at: offset, end: end) else {
                throw invalid("Photoshop 資源結構")
            }
            let identifier = UInt64(try reader.byte(offset + 4)) << 8 | UInt64(try reader.byte(offset + 5))
            guard supported.contains(identifier) else { throw invalid("Photoshop 資源 \(identifier)") }
            // A Pascal resource name is separate from its decoded value. The
            // tag-copy path does not certify that label, even for a known ID.
            guard try reader.byte(offset + 6) == 0 else { throw invalid("Photoshop 資源名稱") }
            let nameLength = UInt64(try reader.byte(offset + 6)) + 1
            let nameBytes = nameLength + nameLength % 2
            guard nameBytes <= end - offset - 6, end - offset - 6 - nameBytes >= 4 else { throw invalid("Photoshop 資源名稱") }
            let sizeOffset = offset + 6 + nameBytes
            let length = try reader.uint32(sizeOffset)
            let paddedLength = length + length % 2
            guard paddedLength <= end - sizeOffset - 4 else { throw invalid("Photoshop 資源長度") }
            offset = sizeOffset + 4 + paddedLength
        }
    }

    private static func invalid(_ detail: String) -> PhotoError {
        PhotoError("來源含有無法確認完整保留的 \(detail)，已停止轉檔；請保留原件。")
    }

    /// ExifTool reads cICP but cannot write it. Preserve the complete original
    /// SDR RGB declaration (including CRC) when keeping the PNG container.
    static func preservePNGColorDeclaration(source: URL, output: URL) throws {
        let pinned = try FileIdentity.read(source), encoded = try FileIdentity.read(output)
        let original = try Reader(source, size: UInt64(pinned.size))
        guard try original.matches([137, 80, 78, 71, 13, 10, 26, 10], at: 0) else { return }
        func chunks(_ reader: Reader) throws -> [(offset: UInt64, length: UInt64, type: String)] {
            var result: [(UInt64, UInt64, String)] = [], offset: UInt64 = 8
            while offset < reader.size {
                guard result.count < 100_000, reader.size - offset >= 12 else { throw invalid("PNG 區塊") }
                let count = try reader.uint32(offset)
                guard count <= reader.size - offset - 12 else { throw invalid("PNG 區塊長度") }
                result.append((offset, count + 12, try reader.text(offset + 4, count: 4)))
                offset += count + 12
            }
            return result
        }
        let colorChunks = try chunks(original).filter { $0.type == "cICP" }
        guard !colorChunks.isEmpty else { return }
        guard colorChunks.count == 1, colorChunks[0].length == 16 else { throw invalid("重複或無效的 PNG cICP") }
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        try sourceHandle.seek(toOffset: colorChunks[0].offset)
        guard let declaration = try sourceHandle.read(upToCount: 16), declaration.count == 16 else { throw invalid("截斷的 PNG cICP") }
        let target = try Reader(output, size: UInt64(encoded.size))
        guard try target.matches([137, 80, 78, 71, 13, 10, 26, 10], at: 0) else { throw invalid("PNG 輸出簽章") }
        let layout = try chunks(target)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".png-color-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw invalid("PNG 色彩宣告暫存檔")
        }
        let input = try FileHandle(forReadingFrom: output), writer = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? writer.close() }
        func copy(_ start: UInt64, _ length: UInt64) throws {
            try input.seek(toOffset: start)
            var remaining = length
            while remaining > 0 {
                let count = Int(min(1024 * 1024, remaining))
                guard let bytes = try input.read(upToCount: count), bytes.count == count else { throw invalid("PNG 輸出讀回") }
                try writer.write(contentsOf: bytes); remaining -= UInt64(count)
            }
        }
        try copy(0, 8)
        var inserted = false
        for chunk in layout {
            if !inserted, ["PLTE", "IDAT"].contains(chunk.type) {
                try writer.write(contentsOf: declaration); inserted = true
            }
            if chunk.type != "cICP" { try copy(chunk.offset, chunk.length) }
        }
        guard inserted else { throw invalid("PNG 缺少影像區塊") }
        try writer.close(); try input.close()
        try pinned.verify(source); try encoded.verify(output)
        try SafeFileTransaction.syncFile(temporary)
        try SafeFileTransaction.replace(temporary, at: output)
    }

    private final class Reader {
        let size: UInt64
        private let handle: FileHandle
        private var start: UInt64 = 0
        private var buffer: [UInt8] = []
        init(_ url: URL, size: UInt64) throws { self.size = size; handle = try FileHandle(forReadingFrom: url) }
        deinit { try? handle.close() }
        func byte(_ offset: UInt64) throws -> UInt8 {
            guard offset < size else { throw CompressionContainerInventory.invalid("截斷的容器") }
            if offset < start || offset - start >= UInt64(buffer.count) {
                try handle.seek(toOffset: offset)
                buffer = Array(try handle.read(upToCount: Int(min(64 * 1024, size - offset))) ?? Data())
                start = offset
            }
            guard offset - start < UInt64(buffer.count) else { throw CompressionContainerInventory.invalid("讀取不完整") }
            return buffer[Int(offset - start)]
        }
        func uint32(_ offset: UInt64) throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<4 { value = value << 8 | UInt64(try byte(offset + UInt64(index))) }
            return value
        }
        func text(_ offset: UInt64, count: Int) throws -> String {
            String(decoding: try (0..<count).map { try byte(offset + UInt64($0)) }, as: UTF8.self)
        }
        func matches(_ value: [UInt8], at offset: UInt64, end: UInt64? = nil) throws -> Bool {
            let limit = end ?? size
            guard offset <= limit, UInt64(value.count) <= limit - offset else { return false }
            for (index, expected) in value.enumerated() where try byte(offset + UInt64(index)) != expected { return false }
            return true
        }
    }
}
