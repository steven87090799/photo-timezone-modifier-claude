import Foundation

public struct CatalogueProjection: Sendable {
    public let rows: [PhotoItem]
    public let cameras: [(name: String, count: Int)]
    public let missingOffsets: Int
    public let totalBytes: Int64
}

/// Isolated from the UI. Reuse the natural sort order when only progress/status
/// changes. Cache URL paths and sort keys before the comparator, not inside it.
public actor CatalogueIndex {
    private struct Key: Equatable {
        let id: UUID
        let path: String
        let text: String
        let size: Int64
    }
    private var lastKeys: [Key] = []
    private var lastSort: PhotoSort?
    private var order: [Int] = []
    public private(set) var sortPasses = 0
    public init() {}

    public func project(_ items: [PhotoItem], query: String, filter: PhotoFilter,
                        camera: String?, sort: PhotoSort) -> CatalogueProjection {
        let keys = items.map { item -> Key in
            let text: String
            switch sort {
            case .date: text = item.metadata?.dateTimeOriginal ?? "~"
            case .camera: text = item.metadata?.camera ?? "~"
            case .filename, .size: text = ""
            }
            return Key(id: item.id, path: item.url.path, text: text,
                       size: sort == .size ? item.metadata?.fileSize ?? 0 : 0)
        }
        if keys != lastKeys || sort != lastSort {
            order = keys.indices.sorted { a, b in
                let lhs = keys[a], rhs = keys[b]
                if sort == .size && lhs.size != rhs.size { return lhs.size > rhs.size }
                if lhs.text != rhs.text {
                    return sort == .camera ? lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending : lhs.text < rhs.text
                }
                let comparison = lhs.path.localizedStandardCompare(rhs.path)
                if comparison == .orderedSame { return a < b }
                return comparison == .orderedAscending
            }
            lastKeys = keys; lastSort = sort; sortPasses += 1
        }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let rows = order.compactMap { index -> PhotoItem? in
            let item = items[index]
            guard filter.matches(item), camera == nil || item.metadata?.camera == camera else { return nil }
            if !terms.isEmpty {
                let m = item.metadata
                let text = [keys[index].path, m?.make, m?.cameraModel, m?.lensModel, m?.dateTimeOriginal, m?.iso]
                    .compactMap { $0 }.joined(separator: " ")
                guard terms.allSatisfy({ text.localizedStandardContains($0) }) else { return nil }
            }
            return item
        }
        var counts: [String: Int] = [:], missing = 0, bytes: Int64 = 0
        for item in items {
            if let metadata = item.metadata {
                counts[metadata.camera, default: 0] += 1
                if metadata.missingOffsets { missing += 1 }
                let (sum, overflow) = bytes.addingReportingOverflow(max(0, metadata.fileSize ?? 0))
                bytes = overflow ? Int64.max : sum
            }
        }
        return CatalogueProjection(rows: rows,
            cameras: counts.map { (name: $0.key, count: $0.value) }.sorted { $0.name < $1.name },
            missingOffsets: missing, totalBytes: bytes)
    }
}
