import Foundation

public struct StorageUsage: Sendable {
    public let logBytes: Int64
    public let logFiles: Int
    public let historyBytes: Int64
    public let historyFiles: Int
    public let activeTransactionBytes: Int64
    public let activeTransactions: Int
    public let photoBackupBytes: Int64
    public let photoBackups: Int
    public let orphanCandidateBytes: Int64
    public let orphanCandidates: Int

    public var administrativeBytes: Int64 {
        logBytes + historyBytes + activeTransactionBytes
    }
}

public struct StorageCleanupResult: Sendable {
    public let removedFiles: Int
    public let removedBytes: Int64
    public let message: String
}

public struct StorageCandidate: Sendable, Identifiable {
    public let url: URL
    fileprivate let identity: FileIdentity
    public var id: URL { url }
}

/// Explicit storage maintenance. Photo backups are measured but never deleted
/// here. Cleanup is limited to app logs, non-provenance archived manifests and
/// staging files whose identity is proved by an archived transaction.
public enum StorageMaintenance {
    public static func snapshot(photoURLs: [URL]) throws -> StorageUsage {
        try snapshot(photoURLs: photoURLs, support: supportDirectory())
    }

    static func snapshot(photoURLs: [URL], support: URL) throws -> StorageUsage {
        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions", isDirectory: true))
        let logs = try measureFlatDirectory(support.appendingPathComponent("Logs", isDirectory: true),
                                            extensions: ["jsonl"])
        let history = try measureFlatDirectory(store.history, extensions: ["json"])
        let active = try measureFlatDirectory(store.active, extensions: ["json"])
        let photo = try measurePhotoDirectories(photoURLs: photoURLs)
        let candidates = store.recordedOrphans(from: photo.candidates)
        return StorageUsage(
            logBytes: logs.bytes, logFiles: logs.count,
            historyBytes: history.bytes, historyFiles: history.count,
            activeTransactionBytes: active.bytes, activeTransactions: active.count,
            photoBackupBytes: photo.backupBytes, photoBackups: photo.backups,
            orphanCandidateBytes: candidates.values.reduce(0) { saturatedAdd($0, $1.size) }, orphanCandidates: candidates.count
        )
    }

    public static func cleanAdministrativeHistory() throws -> StorageCleanupResult {
        try cleanAdministrativeHistory(support: supportDirectory())
    }

    static func cleanAdministrativeHistory(support: URL) throws -> StorageCleanupResult {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lock = try JobLock(url: support.appendingPathComponent("job.lock"))
        defer { lock.release() }
        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions", isDirectory: true))
        guard !store.hasUnreadableActive, try store.unfinished().isEmpty else {
            throw PhotoError("仍有待人工確認的交易；請先完成交易復原檢查，再清理歷史記錄。")
        }
        let protectedIDs = store.canonicalProvenanceRecordIDs()
        var removed = 0
        var bytes: Int64 = 0
        let fm = FileManager.default

        let logs = support.appendingPathComponent("Logs", isDirectory: true)
        if fm.fileExists(atPath: logs.path) {
            for file in try fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                where file.pathExtension.lowercased() == "jsonl" {
                let identity = try FileIdentity.read(file)
                try fm.removeItem(at: file)
                removed += 1
                bytes = saturatedAdd(bytes, identity.size)
            }
            if removed > 0 { try SafeFileTransaction.syncDirectory(logs) }
        }

        var historyRemoved = false
        for file in try fm.contentsOfDirectory(at: store.history, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            where file.pathExtension.lowercased() == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  store.isKnownHistory(id), !protectedIDs.contains(id) else { continue }
            let identity = try FileIdentity.read(file)
            try fm.removeItem(at: file)
            historyRemoved = true
            removed += 1
            bytes = saturatedAdd(bytes, identity.size)
        }
        if historyRemoved { try SafeFileTransaction.syncDirectory(store.history) }
        return StorageCleanupResult(
            removedFiles: removed, removedBytes: bytes,
            message: "已清除可安全移除的 App logs 與非備份來源證明的歷史交易記錄；照片備份與必要 provenance 記錄未刪除。"
        )
    }

    public static func orphanCandidates(photoURLs: [URL]) throws -> [StorageCandidate] {
        try orphanCandidates(photoURLs: photoURLs, support: supportDirectory())
    }

    static func orphanCandidates(photoURLs: [URL], support: URL) throws -> [StorageCandidate] {
        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions", isDirectory: true))
        return store.recordedOrphans(from: try measurePhotoDirectories(photoURLs: photoURLs).candidates)
            .map { StorageCandidate(url: $0.key, identity: $0.value) }
            .sorted { $0.url.path < $1.url.path }
    }

    public static func cleanOrphanCandidates(photoURLs: [URL], approved: [StorageCandidate]? = nil) throws -> StorageCleanupResult {
        try cleanOrphanCandidates(photoURLs: photoURLs, support: supportDirectory(), approved: approved)
    }

    static func cleanOrphanCandidates(photoURLs: [URL], support: URL,
                                      approved: [StorageCandidate]? = nil) throws -> StorageCleanupResult {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lock = try JobLock(url: support.appendingPathComponent("job.lock"))
        defer { lock.release() }
        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions", isDirectory: true))
        guard !store.hasUnreadableActive else {
            throw PhotoError("有無法讀取的未完交易。請先檢查交易復原，再清理暫存檔。")
        }
        let owned = store.recordedOrphans(from: try measurePhotoDirectories(photoURLs: photoURLs).candidates)
        let selection = approved ?? owned.map { StorageCandidate(url: $0.key, identity: $0.value) }
        let fm = FileManager.default
        var removed = 0
        var bytes: Int64 = 0
        var directories: Set<URL> = []
        for item in selection {
            guard owned[item.url] == item.identity, (try? item.identity.verify(item.url)) != nil else { continue }
            try fm.removeItem(at: item.url)
            directories.insert(item.url.deletingLastPathComponent())
            removed += 1
            bytes = saturatedAdd(bytes, item.identity.size)
        }
        for directory in directories { try SafeFileTransaction.syncDirectory(directory) }
        return StorageCleanupResult(
            removedFiles: removed, removedBytes: bytes,
            message: "已清理身分與既有交易紀錄一致的暫存檔。缺少證明或預覽後變動的檔案已保留。"
        )
    }

    public static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let support = base.appendingPathComponent("PhotoTimezone", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return support
    }

    private static func measureFlatDirectory(_ directory: URL, extensions: Set<String>) throws -> (bytes: Int64, count: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return (0, 0) }
        var bytes: Int64 = 0
        var count = 0
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            where extensions.contains(file.pathExtension.lowercased()) {
            let identity = try FileIdentity.read(file)
            bytes = saturatedAdd(bytes, identity.size)
            count += 1
        }
        return (bytes, count)
    }

    private static func measurePhotoDirectories(photoURLs: [URL])
        throws -> (backupBytes: Int64, backups: Int, candidates: Set<String>) {
        let fm = FileManager.default
        let grouped = Dictionary(grouping: photoURLs.map(\.standardizedFileURL)) {
            $0.deletingLastPathComponent().path
        }
        var backupBytes: Int64 = 0
        var backups = 0
        var candidates: Set<String> = []
        for (directoryPath, photos) in grouped {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            let names = Set(photos.map(\.lastPathComponent))
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) {
                let path = file.standardizedFileURL.path
                let name = file.lastPathComponent
                if isPhotoBackupName(name, photoNames: names) {
                    let identity = try FileIdentity.read(file)
                    backupBytes = saturatedAdd(backupBytes, identity.size)
                    backups += 1
                } else if isCandidateName(name) {
                    candidates.insert(path)
                }
            }
        }
        return (backupBytes, backups, candidates)
    }

    private static func isPhotoBackupName(_ name: String, photoNames: Set<String>) -> Bool {
        if name.hasSuffix("_original") {
            return photoNames.contains(String(name.dropLast("_original".count)))
        }
        for marker in [".before-write-", ".before-restore-"] {
            guard let range = name.range(of: marker), name.hasSuffix(".backup") else { continue }
            let photo = String(name[..<range.lowerBound])
            let tokenEnd = name.index(name.endIndex, offsetBy: -".backup".count)
            let token = String(name[range.upperBound..<tokenEnd])
            if photoNames.contains(photo), UUID(uuidString: token) != nil { return true }
        }
        return false
    }

    private static func isCandidateName(_ name: String) -> Bool {
        if name.hasPrefix(".sidecar-") {
            let remainder = String(name.dropFirst(".sidecar-".count))
            // Older copy jobs used an extensionless sidecar candidate. The
            // integrated writer retains the sidecar extension for ExifTool.
            let components = remainder.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 1 ||
                    (components.count == 2 && ["xmp", "on1", "acr"].contains(components[1].lowercased())) else {
                return false
            }
            return UUID(uuidString: String(components[0])) != nil
        }
        guard name.hasPrefix(".photo-timezone-") else { return false }
        let remainder = String(name.dropFirst(".photo-timezone-".count))
        let token = remainder.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return UUID(uuidString: token) != nil
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(max(0, rhs))
        return overflow ? Int64.max : sum
    }
}
