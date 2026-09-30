import Foundation

public enum PhotoFilter: String, CaseIterable, Sendable {
    case all = "全部", missing = "缺拍攝時區", complete = "有拍攝時區"
    case failed = "失敗", unfinished = "失敗／取消", success = "已完成"

    public func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all: return true
        case .missing: return item.metadata?.missingCaptureOffset == true
        case .complete: return item.metadata?.missingCaptureOffset == false
        case .failed: return item.status == .failed
        case .unfinished: return item.status == .failed || item.status == .cancelled
        case .success: return item.status == .success
        }
    }
}

public enum PhotoSort: String, CaseIterable, Sendable {
    case filename = "檔名", date = "拍攝時間", camera = "相機型號", size = "檔案大小"
}

/// Pure catalogue operations shared by the UI and large-list tests.
public enum PhotoCatalogue {
    public static let pageSize = 200

    public static func filtered(_ items: [PhotoItem], query: String = "", filter: PhotoFilter = .all,
                                camera: String? = nil, sort: PhotoSort = .filename) -> [PhotoItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = items.filter { item in
            guard filter.matches(item), camera == nil || item.metadata?.camera == camera else { return false }
            guard !terms.isEmpty else { return true }
            let metadata = item.metadata
            let haystack = [item.url.path, metadata?.make, metadata?.cameraModel, metadata?.lensModel,
                            metadata?.dateTimeOriginal, metadata?.iso].compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { haystack.localizedStandardContains($0) }
        }
        return matches.sorted { a, b in
            switch sort {
            case .filename: break
            case .date:
                let lhs = a.metadata?.dateTimeOriginal ?? "~", rhs = b.metadata?.dateTimeOriginal ?? "~"
                if lhs != rhs { return lhs < rhs }
            case .camera:
                let lhs = a.metadata?.camera ?? "~", rhs = b.metadata?.camera ?? "~"
                if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
            case .size:
                let lhs = a.metadata?.fileSize ?? 0, rhs = b.metadata?.fileSize ?? 0
                if lhs != rhs { return lhs > rhs }
            }
            return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
        }
    }

    public static func page(_ items: [PhotoItem], index: Int) -> [PhotoItem] {
        let start = min(max(0, index), max(0, (items.count - 1) / pageSize)) * pageSize
        return Array(items.dropFirst(start).prefix(pageSize))
    }

    /// Selection is explicit. Filters never silently expand a write's scope.
    public static func selected(_ items: [PhotoItem], ids: Set<UUID>) -> [PhotoItem] {
        items.filter { ids.contains($0.id) }
    }
}
