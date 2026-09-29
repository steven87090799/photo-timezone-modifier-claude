import Foundation

public enum PhotoStatus: String, Codable, Sendable {
    case pending, ready, skipped, success, failed, cancelled
}

public struct PhotoMetadata: Codable, Sendable {
    public let dateTimeOriginal: String?
    public let offsetOriginal: String?
    public let offsetDigitized: String?
    public let offsetTime: String?
    public let fileType: String?
    public let createDate: String?
    public let modifyDate: String?
    public let dateTags: [String: String]
    public var make: String? = nil
    public var cameraModel: String? = nil
    public var lensModel: String? = nil
    public var iso: String? = nil
    public var exposureTime: String? = nil
    public var aperture: String? = nil
    public var focalLength: String? = nil
    public var imageWidth: String? = nil
    public var imageHeight: String? = nil
    public var fileSize: Int64? = nil
    public var camera: String { cameraModel ?? make ?? "未知相機" }
    public var dimensions: String? {
        guard let imageWidth, let imageHeight else { return nil }
        return "\(imageWidth) × \(imageHeight)"
    }
    public var missingOffsets: Bool {
        offsetOriginal == nil || offsetDigitized == nil || offsetTime == nil
    }
}

public struct PhotoItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let url: URL
    public var status: PhotoStatus
    public var detail: String
    public var metadata: PhotoMetadata?
    public var outputURL: URL? = nil
    public var outputMetadata: PhotoMetadata? = nil

    public init(url: URL, status: PhotoStatus = .pending, detail: String = "") {
        self.id = UUID()
        self.url = url
        self.status = status
        self.detail = detail
    }
}

public enum WriteMode: String, CaseIterable, Sendable {
    case fillMissing, replaceAll
}

public struct UTCOffset: Identifiable, Hashable, Sendable {
    public let minutes: Int
    public var id: Int { minutes }
    public init(minutes: Int) { self.minutes = minutes }
    public var isValid: Bool { (-720...840).contains(minutes) && minutes % 15 == 0 }
    public var value: String {
        String(format: "%@%02d:%02d", minutes < 0 ? "-" : "+", abs(minutes) / 60, abs(minutes) % 60)
    }
    public var label: String { "UTC\(value)" }
    // Every quarter hour, including half-hour and 45-minute offsets.
    public static let all = stride(from: -720, through: 840, by: 15).map(UTCOffset.init)
}

public enum JobOperation: Sendable {
    case inspect
    case write(offset: UTCOffset, mode: WriteMode)
    case writeCopy(offset: UTCOffset, mode: WriteMode, destination: URL, sourceRoots: [URL])
    case restore

    var label: String {
        switch self {
        case .inspect: return "檢查"
        case .write(let offset, let mode):
            return "替換原檔 \(offset.label) / \(mode == .fillMissing ? "補齊缺漏" : "覆寫時區")"
        case .writeCopy(let offset, let mode, _, _):
            return "輸出副本 \(offset.label) / \(mode == .fillMissing ? "補齊缺漏" : "覆寫時區")"
        case .restore: return "復原"
        }
    }
}

public struct JobSummary: Sendable {
    public var total: Int
    public var succeeded: Int
    public var skipped: Int
    public var failed: Int
    public var cancelled: Int
    public var logURL: URL?
    public var message: String
}

public enum JobEvent: Sendable {
    case discovered([PhotoItem])
    case updated(PhotoItem, completed: Int, total: Int)
    case phase(String)
    case finished(JobSummary)
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct PhotoError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum EngineResources {
    public static let version = "13.59"
    public static func exiftoolURL(in bundle: Bundle = .main) throws -> URL {
        guard let resources = bundle.resourceURL else { throw PhotoError("找不到 App 資源。") }
        let url = resources.appendingPathComponent("ExifTool/exiftool")
        guard FileManager.default.isReadableFile(atPath: url.path),
              FileManager.default.isReadableFile(atPath: resources.appendingPathComponent("ExifTool/lib/Image/ExifTool.pm").path)
        else { throw PhotoError("App 內的 ExifTool 不完整，請重新執行 build.sh 建置。") }
        return url
    }
}
