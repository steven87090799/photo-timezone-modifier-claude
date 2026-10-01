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
    public var cameraSerialNumber: String? = nil
    public var bodySerialNumber: String? = nil
    public var lensMake: String? = nil
    public var lensModel: String? = nil
    public var lensModelSource: String? = nil
    public var lensInfo: String? = nil
    public var lensSerialNumber: String? = nil
    public var compatibilityIssues: [String] = []

    // Important EXIF preview fields. These are read-only display values; the
    // write pipeline still authorizes only the three OffsetTime* tags.
    public var subSecTimeOriginal: String? = nil
    public var subSecTimeDigitized: String? = nil
    public var subSecTime: String? = nil
    public var iso: String? = nil
    public var exposureTime: String? = nil
    public var aperture: String? = nil
    public var exposureProgram: String? = nil
    public var exposureCompensation: String? = nil
    public var meteringMode: String? = nil
    public var flash: String? = nil
    public var focalLength: String? = nil
    public var focalLength35mm: String? = nil
    public var whiteBalance: String? = nil
    public var sceneCaptureType: String? = nil
    public var orientation: String? = nil
    public var colorSpace: String? = nil
    public var software: String? = nil
    public var mimeType: String? = nil
    public var gpsVersionID: String? = nil
    public var gpsLatitude: String? = nil
    public var gpsLatitudeRef: String? = nil
    public var gpsLongitude: String? = nil
    public var gpsLongitudeRef: String? = nil
    public var gpsAltitude: String? = nil
    public var gpsAltitudeRef: String? = nil
    public var gpsDateStamp: String? = nil
    public var gpsTimeStamp: String? = nil
    public var embeddedEXIFGPSDetected: Bool = false
    public var embeddedXMPGPSDetected: Bool = false
    public var sidecarGPSDetected: Bool = false
    public var gpsSafetyUncertain: Bool = false
    public var imageWidth: String? = nil
    public var imageHeight: String? = nil
    public var fileSize: Int64? = nil
    public var camera: String { cameraModel ?? make ?? "未知相機" }
    public var dimensions: String? {
        guard let imageWidth, let imageHeight else { return nil }
        return "\(imageWidth) × \(imageHeight)"
    }
    public var missingOffsets: Bool {
        !TimeValidation.isOffset(offsetOriginal) || !TimeValidation.isOffset(offsetDigitized) || !TimeValidation.isOffset(offsetTime)
    }
    public var missingCaptureOffset: Bool { !TimeValidation.isOffset(offsetOriginal) }

    /// Manual GPS insertion is allowed only when no embedded EXIF GPS, embedded
    /// XMP GPS, or XMP sidecar GPS is present. Partial GPS is treated as
    /// existing metadata and is never silently overwritten.
    public var hasEmbeddedEXIFGPS: Bool {
        embeddedEXIFGPSDetected || [gpsVersionID, gpsLatitude, gpsLatitudeRef, gpsLongitude, gpsLongitudeRef,
         gpsAltitude, gpsAltitudeRef, gpsDateStamp, gpsTimeStamp].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    public var hasCompleteGPSCoordinate: Bool { gpsLatitude != nil && gpsLongitude != nil }
    public var hasAnyGPS: Bool { hasEmbeddedEXIFGPS || embeddedXMPGPSDetected || sidecarGPSDetected }
    public var canSafelyAddGPS: Bool { !hasAnyGPS && !gpsSafetyUncertain }
}

public struct GPSCoordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitudeMeters: Double?

    public init(latitude: Double, longitude: Double, altitudeMeters: Double? = nil) throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            throw PhotoError("GPS 經緯度超出範圍；緯度需介於 -90～90，經度需介於 -180～180。")
        }
        if let altitudeMeters {
            guard altitudeMeters.isFinite, (-12000.0...100000.0).contains(altitudeMeters) else {
                throw PhotoError("GPS 高度超出合理範圍（-12000～100000 公尺）。")
            }
        }
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
    }

    public static func parse(latitude: String, longitude: String, altitude: String) throws -> GPSCoordinate {
        func number(_ raw: String, name: String, required: Bool) throws -> Double? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if required { throw PhotoError("\(name)不可留空。") }
                return nil
            }
            guard let value = Double(trimmed), value.isFinite else {
                throw PhotoError("\(name)格式錯誤；請輸入十進位數字，例如 25.0330。")
            }
            return value
        }
        return try GPSCoordinate(
            latitude: number(latitude, name: "緯度", required: true)!,
            longitude: number(longitude, name: "經度", required: true)!,
            altitudeMeters: number(altitude, name: "高度", required: false)
        )
    }

    private func decimal(_ value: Double) -> String {
        var text = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains(".") && text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    public var latitudeArgument: String { decimal(abs(latitude)) }
    public var longitudeArgument: String { decimal(abs(longitude)) }
    public var altitudeArgument: String? { altitudeMeters.map { decimal(abs($0)) } }
    public var latitudeRef: String { latitude < 0 ? "S" : "N" }
    public var longitudeRef: String { longitude < 0 ? "W" : "E" }
    public var altitudeRef: String? { altitudeMeters.map { $0 < 0 ? "1" : "0" } }
    public var display: String {
        var value = "\(decimal(latitude)), \(decimal(longitude))"
        if let altitudeMeters { value += " · \(decimal(altitudeMeters)) m" }
        return value
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
    public var sourceIdentity: FileIdentity? = nil
    public var transactionID: UUID? = nil
    public var publicationUnconfirmed: Bool = false
    public var backupURL: URL? = nil

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

public struct WriteOptions: Sendable {
    public let sonyCompatibility: Bool

    /// The GUI and API always operate on all three standard EXIF offset fields.
    /// Existing values are retained by fillMissing; replaceAll changes offsets,
    /// never timestamps.
    public static let appDefault = WriteOptions()

    public let copySidecars: Bool
    public init(sonyCompatibility: Bool = true, copySidecars: Bool = true) {
        self.sonyCompatibility = sonyCompatibility
        self.copySidecars = copySidecars
    }
}

public struct UTCOffset: Identifiable, Hashable, Sendable {
    public let minutes: Int
    public var id: Int { minutes }
    public init(minutes: Int) { self.minutes = minutes }
    public var isValid: Bool { (-720...840).contains(minutes) && minutes % 15 == 0 }
    public var value: String {
        String(format: "%@%02llu:%02llu", minutes < 0 ? "-" : "+", UInt64(minutes.magnitude / 60), UInt64(minutes.magnitude % 60))
    }
    public var label: String { "UTC\(value)" }
    // Every quarter hour, including half-hour and 45-minute offsets.
    public static let all = stride(from: -720, through: 840, by: 15).map(UTCOffset.init)
}

public enum JobOperation: Sendable {
    case inspect
    case write(offset: UTCOffset, mode: WriteMode, options: WriteOptions = WriteOptions())
    case writeCopy(offset: UTCOffset, mode: WriteMode, destination: URL, sourceRoots: [URL], options: WriteOptions = WriteOptions())
    case addGPS(location: GPSCoordinate, options: WriteOptions = WriteOptions())
    case addGPSCopy(location: GPSCoordinate, destination: URL, sourceRoots: [URL], options: WriteOptions = WriteOptions())
    case restore

    var label: String {
        switch self {
        case .inspect: return "檢查"
        case .write(let offset, let mode, let options):
            return "替換原檔 \(offset.label) / 三個 EXIF 時區 / \(mode == .fillMissing ? "補齊缺漏" : "覆寫時區") / Sony \(options.sonyCompatibility ? "相容" : "嚴格")"
        case .writeCopy(let offset, let mode, _, _, let options):
            return "輸出副本 \(offset.label) / 三個 EXIF 時區 / \(mode == .fillMissing ? "補齊缺漏" : "覆寫時區") / Sony \(options.sonyCompatibility ? "相容" : "嚴格")"
        case .addGPS(let location, let options):
            return "替換原檔 / 新增 GPS \(location.display) / Sony \(options.sonyCompatibility ? "相容" : "嚴格")"
        case .addGPSCopy(let location, _, _, let options):
            return "輸出副本 / 新增 GPS \(location.display) / Sony \(options.sonyCompatibility ? "相容" : "嚴格")"
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
