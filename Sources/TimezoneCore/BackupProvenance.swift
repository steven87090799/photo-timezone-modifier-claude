import Foundation

/// Provenance for the first, immutable _original backup.
///
/// A readable file named *_original is not trusted by name alone. Automatic
/// restore is allowed only when this record proves the backup was created by
/// PhotoTimezone for the same source path and the backup identity still
/// matches. No image/content hash is required.
struct BackupProvenanceRecord: Codable, Sendable {
    let version: Int
    let source: URL
    let backup: URL
    let sourceIdentityAtBackup: FileIdentity
    let backupIdentity: FileIdentity
    let transactionID: UUID
    let createdAt: Date
}

enum BackupProvenance {
    private static let currentVersion = 1

    private static func supportDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("PhotoTimezone/BackupProvenance", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    /// Stable path key without pulling image bytes into memory.
    private static func key(for source: URL) -> String {
        var value: UInt64 = 1469598103934665603
        for byte in source.standardizedFileURL.path.utf8 {
            value ^= UInt64(byte)
            value &*= 1099511628211
        }
        return String(value, radix: 16)
    }

    static func record(
        source: URL, sourceIdentity: FileIdentity, backup: URL, transactionID: UUID
    ) throws {
        let backupIdentity = try FileIdentity.read(backup)
        let record = BackupProvenanceRecord(
            version: currentVersion,
            source: source.standardizedFileURL,
            backup: backup.standardizedFileURL,
            sourceIdentityAtBackup: sourceIdentity,
            backupIdentity: backupIdentity,
            transactionID: transactionID,
            createdAt: Date()
        )
        let directory = try supportDirectory()
        let destination = directory.appendingPathComponent(key(for: source) + ".json")
        let temporary = directory.appendingPathComponent(".provenance-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: try encoder.encode(record),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PhotoError("無法建立原始備份來源紀錄；原檔未替換。")
        }
        try SafeFileTransaction.syncFile(temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            try SafeFileTransaction.replace(temporary, at: destination)
        } else {
            try SafeFileTransaction.publishExclusive(temporary, to: destination)
        }
    }

    @discardableResult
    static func verify(source: URL, backup: URL) throws -> BackupProvenanceRecord {
        let source = source.standardizedFileURL
        let backup = backup.standardizedFileURL
        let file = try supportDirectory().appendingPathComponent(key(for: source) + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw PhotoError(
                "找到 _original，但沒有本 App 建立的來源紀錄。為避免還原錯誤照片，已拒絕自動使用；請先人工確認或移開這個舊備份。"
            )
        }
        let identity = try FileIdentity.read(file)
        guard identity.size <= 1024 * 1024 else {
            throw PhotoError("原始備份來源紀錄異常過大；已拒絕自動還原。")
        }
        let record = try JSONDecoder().decode(
            BackupProvenanceRecord.self, from: Data(contentsOf: file)
        )
        guard record.version == currentVersion,
              record.source.standardizedFileURL == source,
              record.backup.standardizedFileURL == backup else {
            throw PhotoError("原始備份來源紀錄與目前照片路徑不符；已拒絕自動還原。")
        }
        try record.backupIdentity.verify(backup)
        return record
    }

    static func removeRecord(for source: URL) throws {
        let file = try supportDirectory().appendingPathComponent(key(for: source) + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
            try SafeFileTransaction.syncDirectory(file.deletingLastPathComponent())
        }
    }

    static func records() throws -> [BackupProvenanceRecord] {
        let directory = try supportDirectory()
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.compactMap { file in
            guard let identity = try? FileIdentity.read(file), identity.size <= 1024 * 1024,
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(BackupProvenanceRecord.self, from: data)
            else { return nil }
            return record
        }
    }
}
