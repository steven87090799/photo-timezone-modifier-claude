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

/// Explicit storage maintenance. Photo backups are measured but never deleted
/// here. Cleanup is limited to app logs, non-provenance archived manifests and
/// UUID-named staging files that no active transaction references.
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
        let photo = try measurePhotoDirectories(photoURLs: photoURLs, activeCandidates: store.activeCandidatePaths())
        return StorageUsage(
            logBytes: logs.bytes, logFiles: logs.count,
            historyBytes: history.bytes, historyFiles: history.count,
            activeTransactionBytes: active.bytes, activeTransactions: active.count,
            photoBackupBytes: photo.backupBytes, photoBackups: photo.backups,
            orphanCandidateBytes: photo.candidateBytes, orphanCandidates: photo.candidates
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
        guard try store.unfinished().isEmpty else {
            throw PhotoError("仍有待人工確認的交易；請先完成交易復原檢查，再清理歷史記錄。")
        }
        let protectedIDs = try store.canonicalProvenanceRecordIDs()
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
                  !protectedIDs.contains(id) else { continue }
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

    public static func cleanOrphanCandidates(photoURLs: [URL]) throws -> StorageCleanupResult {
        try cleanOrphanCandidates(photoURLs: photoURLs, support: supportDirectory())
    }

    static func cleanOrphanCandidates(photoURLs: [URL], support: URL) throws -> StorageCleanupResult {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let lock = try JobLock(url: support.appendingPathComponent("job.lock"))
        defer { lock.release() }
        let store = try TransactionStore(directory: support.appendingPathComponent("Transactions", isDirectory: true))
        _ = try store.unfinished()
        let active = try store.activeCandidatePaths()
        let directories = uniquePhotoDirectories(photoURLs)
        let fm = FileManager.default
        var removed = 0
        var bytes: Int64 = 0
        for directory in directories {
            var changed = false
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) {
                let path = file.standardizedFileURL.path
                guard !active.contains(path), isOwnedCandidateName(file.lastPathComponent) else { continue }
                let identity = try FileIdentity.read(file)
                try identity.verify(file)
                try fm.removeItem(at: file)
                changed = true
                removed += 1
                bytes = saturatedAdd(bytes, identity.size)
            }
            if changed { try SafeFileTransaction.syncDirectory(directory) }
        }
        return StorageCleanupResult(
            removedFiles: removed, removedBytes: bytes,
            message: "已清除目前相片資料夾中未被 active transaction 引用的 PhotoTimezone UUID 暫存候選；照片、_original 與歷史備份未刪除。"
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

    private static func measurePhotoDirectories(photoURLs: [URL], activeCandidates: Set<String>)
        throws -> (backupBytes: Int64, backups: Int, candidateBytes: Int64, candidates: Int) {
        let fm = FileManager.default
        let grouped = Dictionary(grouping: photoURLs.map(\.standardizedFileURL)) {
            $0.deletingLastPathComponent().path
        }
        var backupBytes: Int64 = 0, candidateBytes: Int64 = 0
        var backups = 0, candidates = 0, seen = Set<String>()
        for (directoryPath, photos) in grouped {
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            let names = Set(photos.map(\.lastPathComponent))
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) {
                let path = file.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let name = file.lastPathComponent
                if isPhotoBackupName(name, photoNames: names) {
                    let identity = try FileIdentity.read(file)
                    backupBytes = saturatedAdd(backupBytes, identity.size)
                    backups += 1
                } else if !activeCandidates.contains(path), isOwnedCandidateName(name) {
                    let identity = try FileIdentity.read(file)
                    candidateBytes = saturatedAdd(candidateBytes, identity.size)
                    candidates += 1
                }
            }
        }
        return (backupBytes, backups, candidateBytes, candidates)
    }

    private static func uniquePhotoDirectories(_ photoURLs: [URL]) -> [URL] {
        var seen = Set<String>(), result: [URL] = []
        for photo in photoURLs {
            let directory = photo.standardizedFileURL.deletingLastPathComponent()
            if seen.insert(directory.path).inserted { result.append(directory) }
        }
        return result
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

    private static func isOwnedCandidateName(_ name: String) -> Bool {
        if name.hasPrefix(".sidecar-") {
            return UUID(uuidString: String(name.dropFirst(".sidecar-".count))) != nil
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
