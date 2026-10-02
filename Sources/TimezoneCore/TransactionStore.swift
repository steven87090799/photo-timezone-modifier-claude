import Foundation

public enum TransactionPhase: String, Codable, Sendable {
    case prepared, backupDurable, published, committed, aborted, publicationUnconfirmed, reviewed
}

/// Small durable manifest, written BEFORE changing an original. Offsets and
/// original date fields enable review without another whole-file read/hash.
struct TransactionManifest: Codable {
    let version: Int
    let id: UUID
    let source: URL
    let target: URL
    let candidate: URL
    var backup: URL?
    let sourceIdentity: FileIdentity
    var targetIdentityBefore: FileIdentity? = nil
    var candidateIdentity: FileIdentity?
    /// Present for the canonical <photo>_original backup created by this app.
    /// Old manifests decode with nil and can still be accepted only through the
    /// stricter committed-transaction legacy provenance path.
    var canonicalBackupIdentity: FileIdentity? = nil
    /// App-owned hidden sidecar staging files. Optional for journal compatibility.
    var sidecarCandidateIdentities: [String: FileIdentity]? = nil
    let originalDates: [String: String]
    let oldOffsets: [String: String]
    let newOffsets: [String: String]
    var sidecarTargets: [URL]
    var publishedSidecars: [URL]
    var phase: TransactionPhase
    var detail: String
}

final class TransactionStore {
    let active: URL
    let history: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }()

    init(directory: URL) throws {
        active = directory.appendingPathComponent("active", isDirectory: true)
        history = directory.appendingPathComponent("history", isDirectory: true)
        for dir in [active, history] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
    }

    func save(_ manifest: TransactionManifest) throws {
        let destination = active.appendingPathComponent("\(manifest.id.uuidString).json")
        let temp = active.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: try encoder.encode(manifest),
                                            attributes: [.posixPermissions: 0o600]) else {
            throw PhotoError("Cannot persist transaction intent; no new original will be modified.")
        }
        try SafeFileTransaction.syncFile(temp)
        if FileManager.default.fileExists(atPath: destination.path) {
            try SafeFileTransaction.replace(temp, at: destination)
        } else {
            try SafeFileTransaction.publishExclusive(temp, to: destination)
        }
    }

    func finish(_ manifest: TransactionManifest) throws {
        try save(manifest)
        let file = active.appendingPathComponent("\(manifest.id.uuidString).json")
        let target = history.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            throw PhotoError("Transaction history collision; active recovery record was retained.")
        }
        try SafeFileTransaction.publishExclusive(file, to: target)
        try SafeFileTransaction.syncDirectory(active)
    }

    /// The canonical _original is trusted only when a durable transaction from
    /// this app references the exact source/backup pair. New records additionally
    /// pin the backup FileIdentity so a replaced file is never accepted.
    func verifyCanonicalOriginalBackup(_ backup: URL, source: URL) throws {
        let backup = backup.standardizedFileURL
        let source = source.standardizedFileURL
        guard backup.path == source.path + "_original" else {
            throw PhotoError("Backup is not the canonical _original path for this photo.")
        }
        let current = try FileIdentity.read(backup)
        var sawReference = false
        for record in try allRecords() {
            guard record.source.standardizedFileURL.path == source.path,
                  record.backup?.standardizedFileURL.path == backup.path else { continue }
            sawReference = true
            if let pinned = record.canonicalBackupIdentity {
                let durablePhases: Set<TransactionPhase> = [
                    .backupDurable, .published, .committed, .aborted, .publicationUnconfirmed, .reviewed
                ]
                if durablePhases.contains(record.phase), pinned == current { return }
                continue
            }

            // Compatibility for backups made by versions that already had
            // durable committed transaction manifests but not the identity pin.
            let legacyPhases: Set<TransactionPhase> = [.committed, .publicationUnconfirmed, .reviewed]
            guard legacyPhases.contains(record.phase) else { continue }
            if current.size == record.sourceIdentity.size,
               current.modifiedSeconds == record.sourceIdentity.modifiedSeconds,
               current.modifiedNanoseconds == record.sourceIdentity.modifiedNanoseconds,
               current.mode & 0o7777 == record.sourceIdentity.mode & 0o7777 {
                return
            }
        }
        if sawReference {
            throw PhotoError("The _original backup no longer matches the backup identity recorded by this app. Automatic restore/write is blocked.")
        }
        throw PhotoError("Existing _original has no trusted PhotoTimezone provenance. It will not be used or overwritten automatically; move/rename it or use copy mode.")
    }

    func canonicalProvenanceRecordIDs() throws -> Set<UUID> {
        var ids = Set<UUID>()
        for record in try allRecords() {
            guard let backup = record.backup,
                  backup.standardizedFileURL.path == record.source.standardizedFileURL.path + "_original" else { continue }
            if record.canonicalBackupIdentity != nil ||
               [.committed, .publicationUnconfirmed, .reviewed].contains(record.phase) {
                ids.insert(record.id)
            }
        }
        return ids
    }

    func activeCandidatePaths() throws -> Set<String> {
        var result = Set<String>()
        for record in try records(in: active) {
            result.insert(record.candidate.standardizedFileURL.path)
            for path in record.sidecarCandidateIdentities.map({ Array($0.keys) }) ?? [] {
                result.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        return result
    }

    private func allRecords() throws -> [TransactionManifest] {
        try records(in: active) + records(in: history)
    }

    private func records(in directory: URL) throws -> [TransactionManifest] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )
        return try files.filter { $0.pathExtension == "json" }.map(decode)
    }

    private func decode(_ file: URL) throws -> TransactionManifest {
        let identity = try FileIdentity.read(file)
        guard identity.size <= 1024 * 1024 else {
            throw PhotoError("Oversized recovery manifest; inspect \(file.path)")
        }
        return try JSONDecoder().decode(TransactionManifest.self, from: Data(contentsOf: file))
    }

    func unfinished() throws -> [TransactionManifest] {
        let files = try FileManager.default.contentsOfDirectory(at: active,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        var pending: [TransactionManifest] = []
        for file in files where file.pathExtension == "json" {
            var record = try decode(file)
            if record.phase == .committed || record.phase == .aborted || record.phase == .reviewed {
                // Recovery after the final durable record but before archival.
                let target = history.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try SafeFileTransaction.publishExclusive(file, to: target)
                }
                continue
            }

            let staged = try? FileIdentity.read(record.candidate)
            let visibleBefore = try? FileIdentity.read(record.target)
            let targetUnchanged = record.targetIdentityBefore.map { $0 == visibleBefore }
                ?? (!FileManager.default.fileExists(atPath: record.target.path))
            if let staged, let expected = record.candidateIdentity, staged == expected,
               targetUnchanged, record.publishedSidecars.isEmpty,
               record.phase == .prepared || record.phase == .backupDurable {
                do {
                    try removeOwnedCandidate(record.candidate, expected: expected,
                                             prefix: ".photo-timezone-", beside: record.target)
                    if let sidecars = record.sidecarCandidateIdentities {
                        for (path, identity) in sidecars {
                            try removeOwnedCandidate(URL(fileURLWithPath: path), expected: identity,
                                                     prefix: ".sidecar-", beside: record.target)
                        }
                    }
                    record.phase = .aborted
                    record.detail = "Recovered before publication: disposable photo/sidecar candidates were removed; destination unchanged and backups retained."
                    try finish(record)
                    continue
                } catch {
                    record.detail = "Publication did not occur, but safe staging cleanup needs review: \(error.localizedDescription)"
                    try save(record)
                    pending.append(record)
                    continue
                }
            }

            // Never infer 'not published' solely from an old phase: the process
            // may have stopped immediately after rename, before updating it.
            let visible = try? FileIdentity.read(record.target)
            if let visible, let candidate = record.candidateIdentity,
               visible.device == candidate.device && visible.inode == candidate.inode {
                record.phase = .publicationUnconfirmed
                record.detail = "Candidate is visible at target; review required before retry. Backups retained."
                try save(record)
            }
            pending.append(record)
        }
        return pending
    }

    private func removeOwnedCandidate(_ url: URL, expected: FileIdentity,
                                      prefix: String, beside target: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL.path ==
                target.deletingLastPathComponent().standardizedFileURL.path else {
            throw PhotoError("Staging candidate is outside the transaction directory; not removed.")
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        guard baseName.hasPrefix(prefix) else {
            throw PhotoError("Staging candidate name is not app-owned; not removed.")
        }
        let token = String(baseName.dropFirst(prefix.count))
        guard UUID(uuidString: token) != nil else {
            throw PhotoError("Staging candidate UUID is invalid; not removed.")
        }
        try expected.verify(url)
        try FileManager.default.removeItem(at: url)
        try SafeFileTransaction.syncDirectory(url.deletingLastPathComponent())
    }
}
