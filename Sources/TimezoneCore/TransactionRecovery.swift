import Foundation

public struct RecoveryEntry: Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let target: URL
    public let backup: URL?
    public let sidecars: [URL]
    public let detail: String
    public let phase: TransactionPhase
    public let targetIdentity: FileIdentity?
}

public enum TransactionRecovery {
    public static func directory() throws -> URL {
        try support().appendingPathComponent("Transactions", isDirectory: true)
    }
    private static func support() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("PhotoTimezone", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Called off the UI actor and protected by the SAME lock as photo jobs.
    /// Merely inspecting recovery records never rewrites or removes a photo.
    public static func pending() throws -> [RecoveryEntry] {
        let lock = try JobLock(url: support().appendingPathComponent("job.lock"))
        defer { lock.release() }
        return try TransactionStore(directory: directory()).unfinished().map { record in
            RecoveryEntry(id: record.id, source: record.source, target: record.target,
                backup: record.backup, sidecars: record.sidecarTargets,
                detail: record.detail, phase: record.phase, targetIdentity: try? FileIdentity.read(record.target))
        }
    }

    /// Requires an explicit human acknowledgement in the UI. This only archives
    /// an administrative record; it does NOT certify bytes, restore a photo,
    /// remove a backup, publish a missing sidecar, or automatically retry a job.
    public static func acknowledgeReviewed(_ entry: RecoveryEntry) throws {
        let lock = try JobLock(url: support().appendingPathComponent("job.lock"))
        defer { lock.release() }
        let store = try TransactionStore(directory: directory())
        guard var record = try store.unfinished().first(where: { $0.id == entry.id }),
              record.target == entry.target else { throw PhotoError("Recovery record changed; refresh the review list.") }
        let identity = try? FileIdentity.read(record.target)
        guard identity == entry.targetIdentity else { throw PhotoError("Target changed since review; inspect it again before acknowledging.") }
        record.phase = .reviewed
        record.detail += "\nExplicitly acknowledged by user after manual review. Photos/backups untouched; a new preview is required."
        try store.finish(record)
    }
}
