import Foundation

/// Prepare the single colour property in a freshly encoded ImageIO HEIF for
/// ExifTool's ICC block writer. ExifTool can replace prof/rICC, but silently
/// leaves a pre-existing nclx property unchanged when asked to add ICC.
/// Only the four-byte property discriminator is changed here. ExifTool then
/// writes the actual profile and updates all box sizes and item offsets.
/// The output is disposable until ICC equality and ImageIO decoding pass.
enum HEIFICCProfile {
    private struct Box {
        let payload: Int
        let end: Int
        let type: String
    }

    static func prepareForWrite(_ file: URL) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var position: UInt64 = 0
        var markers: [UInt64] = []
        var colourProperties = 0
        while position < fileSize {
            guard fileSize - position >= 8 else { throw invalidContainer() }
            try handle.seek(toOffset: position)
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header.count >= 8 else { throw invalidContainer() }
            let shortSize = unsigned(header, at: 0, count: 4)
            let headerSize: UInt64 = shortSize == 1 ? 16 : 8
            if shortSize == 1 && header.count < 16 { throw invalidContainer() }
            let size = shortSize == 0 ? fileSize - position :
                shortSize == 1 ? unsigned(header, at: 8, count: 8) : shortSize
            guard size >= headerSize, size <= fileSize - position else { throw invalidContainer() }
            if type(header, at: 4) == "meta" {
                let length = size - headerSize
                guard length >= 4, length <= 16 * 1024 * 1024 else { throw invalidContainer() }
                try handle.seek(toOffset: position + headerSize)
                let metadata = try handle.read(upToCount: Int(length)) ?? Data()
                guard metadata.count == Int(length) else { throw invalidContainer() }
                let children = try boxes(metadata, from: 4, to: metadata.count)
                for properties in children where properties.type == "iprp" {
                    for container in try boxes(metadata, from: properties.payload, to: properties.end) where container.type == "ipco" {
                        for property in try boxes(metadata, from: container.payload, to: container.end) where property.type == "colr" {
                            guard property.end - property.payload >= 4 else { throw invalidContainer() }
                            colourProperties += 1
                            let kind = type(metadata, at: property.payload)
                            if kind == "nclx" {
                                // ImageIO's SDR RGBA output has one shared colour
                                // property. Refuse ambiguous multi-profile files.
                                guard property.end - property.payload == 11 else { throw invalidContainer() }
                                markers.append(position + headerSize + UInt64(property.payload))
                            } else if kind != "prof" && kind != "rICC" {
                                throw invalidContainer()
                            }
                        }
                    }
                }
            }
            position += size
        }
        if markers.isEmpty { return }
        guard colourProperties == 1, markers.count == 1 else { throw invalidContainer() }
        try handle.seek(toOffset: markers[0])
        try handle.write(contentsOf: Data("prof".utf8))
    }

    private static func boxes(_ data: Data, from start: Int, to end: Int) throws -> [Box] {
        var position = start
        var result: [Box] = []
        while position < end {
            guard end - position >= 8 else { throw invalidContainer() }
            let shortSize = unsigned(data, at: position, count: 4)
            let header = shortSize == 1 ? 16 : 8
            guard end - position >= header else { throw invalidContainer() }
            let size = shortSize == 0 ? UInt64(end - position) :
                shortSize == 1 ? unsigned(data, at: position + 8, count: 8) : shortSize
            guard size >= UInt64(header), size <= UInt64(end - position) else { throw invalidContainer() }
            result.append(Box(payload: position + header, end: position + Int(size), type: type(data, at: position + 4)))
            position += Int(size)
        }
        return result
    }

    private static func unsigned(_ data: Data, at start: Int, count: Int) -> UInt64 {
        data[start..<(start + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private static func type(_ data: Data, at start: Int) -> String {
        String(decoding: data[start..<(start + 4)], as: UTF8.self)
    }
    private static func invalidContainer() -> PhotoError {
        PhotoError("HEIF 色彩容器無法安全更新；未接受此輸出。")
    }
}
