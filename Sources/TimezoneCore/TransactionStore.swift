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
        try SafeFileTransaction.publishExclusive(file, to: history.appendingPathComponent(file.lastPathComponent))
        try SafeFileTransaction.syncDirectory(active)
    }

    func unfinished() throws -> [TransactionManifest] {
        let files = try FileManager.default.contentsOfDirectory(at: active,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        var pending: [TransactionManifest] = []
        for file in files where file.pathExtension == "json" {
            let identity = try FileIdentity.read(file)
            guard identity.size <= 1024 * 1024 else { throw PhotoError("Oversized recovery manifest; inspect \(file.path)") }
            var record = try JSONDecoder().decode(TransactionManifest.self, from: Data(contentsOf: file))
            if record.phase == .committed || record.phase == .aborted || record.phase == .reviewed {
                // Recovery after the final durable record but before archival.
                let target = history.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try SafeFileTransaction.publishExclusive(file, to: target)
                }
                continue
            }
            // A still-present, identical candidate plus an unchanged destination
            // proves that OUR atomic rename did not consume this candidate.
            // Leave all photo/backup files untouched; archive only the record.
            let staged = try? FileIdentity.read(record.candidate)
            let visibleBefore = try? FileIdentity.read(record.target)
            let targetUnchanged = record.targetIdentityBefore.map { $0 == visibleBefore }
                ?? (!FileManager.default.fileExists(atPath: record.target.path))
            if let staged, let expected = record.candidateIdentity, staged == expected,
               targetUnchanged, record.publishedSidecars.isEmpty,
               record.phase == .prepared || record.phase == .backupDurable {
                record.phase = .aborted
                record.detail = "Recovered before publication: candidate and destination identities unchanged. Files and backups retained."
                try finish(record)
                continue
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
}
