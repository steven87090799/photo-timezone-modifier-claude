import Foundation

public struct StorageUsageSummary: Sendable {
    public let logsBytes: Int64
    public let transactionHistoryBytes: Int64
    public let activeTransactionBytes: Int64
    public let trackedBackupBytes: Int64
    public let trackedBackupCount: Int
    public let missingTrackedBackups: Int

    public var administrativeBytes: Int64 {
        logsBytes + transactionHistoryBytes + activeTransactionBytes
    }
}

public enum StorageMaintenance {
    private static func support() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("PhotoTimezone", isDirectory: true)
    }

    private static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let value = Int64(values.fileSize ?? 0)
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            total = overflow ? Int64.max : sum
        }
        return total
    }

    public static func summary() throws -> StorageUsageSummary {
        let root = try support()
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let transactions = root.appendingPathComponent("Transactions", isDirectory: true)
        let history = transactions.appendingPathComponent("history", isDirectory: true)
        let active = transactions.appendingPathComponent("active", isDirectory: true)

        var backupBytes: Int64 = 0
        var backupCount = 0
        var missing = 0
        for record in try BackupProvenance.records() {
            if let identity = try? FileIdentity.read(record.backup) {
                backupCount += 1
                let (sum, overflow) = backupBytes.addingReportingOverflow(max(0, identity.size))
                backupBytes = overflow ? Int64.max : sum
            } else {
                missing += 1
            }
        }
        return StorageUsageSummary(
            logsBytes: size(of: logs),
            transactionHistoryBytes: size(of: history),
            activeTransactionBytes: size(of: active),
            trackedBackupBytes: backupBytes,
            trackedBackupCount: backupCount,
            missingTrackedBackups: missing
        )
    }

    /// Deletes only old administrative logs/history. Photo backups, provenance,
    /// and active recovery records are never removed here.
    @discardableResult
    public static func cleanupAdministrativeHistory(olderThanDays days: Int = 30) throws -> Int {
        guard days >= 1 else { throw PhotoError("清理天數至少必須是 1 天。") }
        let root = try support()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let directories = [
            root.appendingPathComponent("Logs", isDirectory: true),
            root.appendingPathComponent("Transactions/history", isDirectory: true)
        ]
        var removed = 0
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
                try FileManager.default.removeItem(at: file)
                removed += 1
            }
            if removed > 0 { try SafeFileTransaction.syncDirectory(directory) }
        }
        return removed
    }
}
