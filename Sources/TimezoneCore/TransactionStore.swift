import Foundation

public enum TransactionPhase: String, Codable, Sendable, Hashable {
    case prepared, backupDurable, published, committed, aborted, publicationUnconfirmed, reviewed
}

/// Small durable manifest, written BEFORE changing an original. Offsets and
/// original date fields enable review without another whole-file read/hash.
struct TransactionManifest: Codable, Equatable {
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
    /// Durable original-sidecar backups for an integrated multi-file write.
    /// Optional so recovery can decode records created by older versions.
    var sidecarBackups: [String: URL]? = nil
    /// Identity pins for the durable sidecar backups, keyed by original path.
    /// A nil map denotes a legacy record that cannot certify bundle restoration.
    var sidecarBackupIdentities: [String: FileIdentity]? = nil
    let originalDates: [String: String]
    let oldOffsets: [String: String]
    let newOffsets: [String: String]
    var sidecarTargets: [URL]
    var publishedSidecars: [URL]
    var phase: TransactionPhase
    var detail: String
}


final class TransactionStore {
    struct RecordIssue {
        let url: URL
        let detail: String
        let blocksWrites: Bool
    }

    struct CanonicalBundle {
        let sidecars: [String: (url: URL, identity: FileIdentity)]
        let legacyGPSOnly: Bool
    }

    private static let manifestLimit = 1024 * 1024
    private static let terminalPhases: Set<TransactionPhase> = [.committed, .aborted, .reviewed]
    let active: URL
    let history: URL
    private(set) var issues: [RecordIssue] = []
    private var activeRecords: [UUID: TransactionManifest] = [:]
    private var archivedIDs: Set<UUID> = []
    private var provenance: [String: [UUID: TransactionManifest]] = [:]
    private let syncAfterArchive: (URL) throws -> Void
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    var hasUnreadableActive: Bool { issues.contains(where: \.blocksWrites) }

    init(directory: URL, syncAfterArchive: @escaping (URL) throws -> Void = SafeFileTransaction.syncDirectory) throws {
        active = directory.appendingPathComponent("active", isDirectory: true)
        history = directory.appendingPathComponent("history", isDirectory: true)
        self.syncAfterArchive = syncAfterArchive
        for dir in [active, history] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        // Prefer active state when recovering records duplicated by older versions.
        try load(history, activeRecords: false)
        try load(active, activeRecords: true)
    }

    private func load(_ directory: URL, activeRecords isActive: Bool) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])
        for file in files where file.pathExtension == "json" {
            do {
                let record = try decode(file)
                if isActive {
                    self.activeRecords[record.id] = record
                } else {
                    guard Self.terminalPhases.contains(record.phase) else {
                        throw PhotoError("Archived recovery record has a non-final state.")
                    }
                    archivedIDs.insert(record.id)
                }
                rememberProvenance(record)
            } catch {
                // Preserve unreadable bytes, which may be the only backup evidence.
                issues.append(RecordIssue(url: file, detail: error.localizedDescription, blocksWrites: isActive))
            }
        }
    }

    func save(_ manifest: TransactionManifest) throws {
        let bytes = try encoder.encode(manifest)
        guard bytes.count <= Self.manifestLimit else {
            throw PhotoError("交易紀錄超過 1 MiB。這筆紀錄無法安全保存。")
        }
        let destination = manifestURL(manifest.id, in: active)
        let temp = active.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: bytes,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw PhotoError("Cannot persist transaction intent; no new original will be modified.")
        }
        if manifest.backup != nil && (manifest.phase != .prepared || !manifest.publishedSidecars.isEmpty) {
            try SafeFileTransaction.fullSyncFile(temp)
        } else {
            try SafeFileTransaction.syncFile(temp)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try SafeFileTransaction.replace(temp, at: destination)
        } else {
            try SafeFileTransaction.publishExclusive(temp, to: destination)
        }
        activeRecords[manifest.id] = manifest
        rememberProvenance(manifest)
    }

    func finish(_ manifest: TransactionManifest) throws {
        guard Self.terminalPhases.contains(manifest.phase) else {
            throw PhotoError("Only a final transaction can be archived.")
        }
        if activeRecords[manifest.id] == nil, archivedIDs.contains(manifest.id) {
            guard try decode(manifestURL(manifest.id, in: history)) == manifest else {
                throw PhotoError("A different transaction state has already been archived.")
            }
            return
        }
        // A durable final record in active already commits the transaction.
        // Archival can be retried; its errors must never roll back that commit.
        try save(manifest)
        archive(manifest)
    }

    private func archive(_ record: TransactionManifest) {
        let source = manifestURL(record.id, in: active)
        let destination = manifestURL(record.id, in: history)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                let old = try decode(destination)
                if old == record {
                    try SafeFileTransaction.syncDirectory(history)
                    try fm.removeItem(at: source)
                } else {
                    // Upgrade an older interrupted archival without discarding its history.
                    guard old.source == record.source, old.target == record.target,
                          old.sourceIdentity == record.sourceIdentity, old.candidate == record.candidate else {
                        throw PhotoError("Transaction history conflicts with the active record; both were kept.")
                    }
                    let prior = history.appendingPathComponent(".prior-\(record.id)-\(UUID().uuidString).json")
                    try SafeFileTransaction.copyAndSync(destination, to: prior)
                    try SafeFileTransaction.syncDirectory(history)
                    try SafeFileTransaction.replace(source, at: destination)
                }
            } else {
                try SafeFileTransaction.publishExclusive(source, to: destination)
            }
            markArchived(record)
            try syncAfterArchive(active)
        } catch {
            // The rename can succeed before directory synchronization throws.
            if !fm.fileExists(atPath: source.path), (try? decode(destination)) == record {
                markArchived(record)
            }
            issues.append(RecordIssue(url: fm.fileExists(atPath: source.path) ? source : destination,
                                      detail: "交易已保存。歷史歸檔仍待確認。\(error.localizedDescription)",
                                      blocksWrites: false))
        }
    }

    private func markArchived(_ record: TransactionManifest) {
        activeRecords.removeValue(forKey: record.id)
        archivedIDs.insert(record.id)
    }

    func verifyCanonicalOriginalBackup(_ backup: URL, source: URL) throws {
        _ = try canonicalRecord(backup, source: source)
    }

    private func canonicalRecord(_ backup: URL, source: URL) throws -> TransactionManifest {
        let backup = backup.standardizedFileURL
        let source = source.standardizedFileURL
        guard backup.path == source.path + "_original" else {
            throw PhotoError("Backup is not the canonical _original path for this photo.")
        }
        let current = try FileIdentity.read(backup)
        let records = provenance[source.path] ?? [:]
        let matches = records.values.filter { record in
            if let pinned = record.canonicalBackupIdentity {
                return record.phase != .prepared && pinned == current
            }
            // Legacy committed records pinned attributes instead of backup inode.
            return [.committed, .publicationUnconfirmed, .reviewed].contains(record.phase)
                && current.size == record.sourceIdentity.size
                && current.modifiedSeconds == record.sourceIdentity.modifiedSeconds
                && current.modifiedNanoseconds == record.sourceIdentity.modifiedNanoseconds
                && current.mode & 0o7777 == record.sourceIdentity.mode & 0o7777
        }
        guard matches.count <= 1 else {
            throw PhotoError("原始照片備份對應多筆交易，無法安全判定原始版本。")
        }
        guard let record = matches.first else {
            if !records.isEmpty {
                throw PhotoError("The _original backup no longer matches its recorded identity. Automatic restore/write is blocked.")
            }
            throw PhotoError("Existing _original has no trusted PhotoTimezone provenance. It will not be used or overwritten automatically.")
        }
        return record
    }

    func canonicalProvenanceRecordIDs() -> Set<UUID> {
        Set(provenance.values.flatMap { records in
            records.values.compactMap { record in
                if record.canonicalBackupIdentity != nil ||
                   [.committed, .publicationUnconfirmed, .reviewed].contains(record.phase) {
                    return record.id
                }
                return nil
            }
        })
    }

    func isKnownHistory(_ id: UUID) -> Bool { archivedIDs.contains(id) }

    /// Resolve only the record that holds the canonical photo backup.
    func canonicalBundle(_ backup: URL, source: URL) throws -> CanonicalBundle {
        let record = try canonicalRecord(backup, source: source)
        let backups = record.sidecarBackups ?? [:]
        guard backups.isEmpty || record.sidecarBackupIdentities != nil else {
            throw PhotoError("舊版交易缺少 XMP 備份身分，未還原。請保留備份並人工核對。")
        }
        let legacyGPSOnly = record.version == 2 && backups.isEmpty && record.sidecarTargets.isEmpty
            && record.detail.hasPrefix("GPS-only metadata addition")
        let names = [source.lastPathComponent, source.deletingPathExtension().lastPathComponent].map(SidecarIndex.key)
        var result: [String: (url: URL, identity: FileIdentity)] = [:]
        for (path, url) in backups {
            let sidecar = URL(fileURLWithPath: path)
            let directory = source.deletingLastPathComponent().standardizedFileURL
            guard ["xmp", "on1", "acr"].contains(sidecar.pathExtension.lowercased()),
                  names.contains(SidecarIndex.key(sidecar.deletingPathExtension().lastPathComponent)),
                  sidecar.deletingLastPathComponent().standardizedFileURL == directory,
                  url.deletingLastPathComponent().standardizedFileURL == directory,
                  let pinned = record.sidecarBackupIdentities?[path] else {
                throw PhotoError("Sidecar 備份資料不完整或位於其他資料夾，未還原。")
            }
            try pinned.verify(url)
            result[path] = (url, pinned)
        }
        return CanonicalBundle(sidecars: result, legacyGPSOnly: legacyGPSOnly)
    }

    private func rememberProvenance(_ record: TransactionManifest) {
        let source = record.source.standardizedFileURL
        guard let backup = record.backup?.standardizedFileURL,
              backup.path == source.path + "_original" else { return }
        provenance[source.path, default: [:]][record.id] = record
    }

    func activeCandidatePaths() -> Set<String> {
        Set(activeRecords.values.flatMap { record in
            [record.candidate.standardizedFileURL.path] + (record.sidecarCandidateIdentities ?? [:]).keys.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        })
    }

    func recordedOrphans(from paths: Set<String>) -> [URL: FileIdentity] {
        guard !paths.isEmpty, !hasUnreadableActive else { return [:] }
        let eligible = paths.subtracting(activeCandidatePaths())
        var orphans: [URL: FileIdentity] = [:]
        for id in archivedIDs {
            guard let record = try? decode(manifestURL(id, in: history)) else { continue }
            for (url, identity) in stagingFiles(for: record) where eligible.contains(url.path) {
                guard ownsCandidate(url, beside: record.target), (try? identity.verify(url)) != nil else { continue }
                orphans[url] = identity
            }
        }
        return orphans
    }

    private func manifestURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func decode(_ file: URL) throws -> TransactionManifest {
        let identity = try FileIdentity.read(file)
        guard identity.size <= Self.manifestLimit else { throw PhotoError("Oversized recovery manifest.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.manifestLimit + 1) ?? Data()
        try identity.verify(file)
        let record = try JSONDecoder().decode(TransactionManifest.self, from: data)
        guard data.count == identity.size,
              record.id == UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
            throw PhotoError("Recovery manifest does not match its file identity.")
        }
        let paths = [record.source, record.target, record.candidate] + record.sidecarTargets +
            record.publishedSidecars + (record.backup.map { [$0] } ?? []) + Array((record.sidecarBackups ?? [:]).values)
        guard (1...4).contains(record.version), paths.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else {
            throw PhotoError("Recovery manifest format or file paths are unsupported.")
        }
        return record
    }

    func unfinished(reconcile: Bool = true) throws -> [TransactionManifest] {
        var pending: [TransactionManifest] = []
        for var record in activeRecords.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if Self.terminalPhases.contains(record.phase) {
                if reconcile && !hasUnreadableActive { archive(record) }
                continue
            }
            if reconcile && !hasUnreadableActive {
                let visible = try? FileIdentity.read(record.target)
                let targetUnchanged = record.targetIdentityBefore.map { $0 == visible }
                    ?? (!FileManager.default.fileExists(atPath: record.target.path))
                let staging = stagingFiles(for: record)
                if record.candidateIdentity != nil, targetUnchanged, record.publishedSidecars.isEmpty,
                   [.prepared, .backupDurable].contains(record.phase),
                   staging.allSatisfy({ ownsCandidate($0.0, beside: record.target) && (try? $0.1.verify($0.0)) != nil }) {
                    do {
                        for (url, identity) in staging {
                            try identity.verify(url)
                            try FileManager.default.removeItem(at: url)
                        }
                        try SafeFileTransaction.syncDirectory(record.target.deletingLastPathComponent())
                        record.phase = .aborted
                        record.detail = "Recovered before publication. Disposable candidates removed and backups retained."
                        try finish(record)
                        continue
                    } catch {
                        record.phase = .publicationUnconfirmed
                        record.detail = "Staging cleanup needs review: \(error.localizedDescription)"
                        try save(record)
                    }
                } else if let visible, let candidate = record.candidateIdentity,
                          visible.device == candidate.device, visible.inode == candidate.inode,
                          record.phase != .publicationUnconfirmed {
                    // A rename can precede the last journal update.
                    record.phase = .publicationUnconfirmed
                    record.detail = "Candidate is visible at target. Backups retained; review required."
                    try save(record)
                }
            }
            pending.append(record)
        }
        return pending
    }

    private func stagingFiles(for record: TransactionManifest) -> [(URL, FileIdentity)] {
        var staging = (record.sidecarCandidateIdentities ?? [:]).map { (URL(fileURLWithPath: $0.key).standardizedFileURL, $0.value) }
        if let identity = record.candidateIdentity { staging.append((record.candidate.standardizedFileURL, identity)) }
        return staging
    }

    private func ownsCandidate(_ url: URL, beside target: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL else {
            return false
        }
        let name = url.deletingPathExtension().lastPathComponent
        for prefix in [".photo-timezone-", ".sidecar-"] where name.hasPrefix(prefix) {
            return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
        return false
    }
}
