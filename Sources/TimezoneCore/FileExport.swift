import Foundation

public enum FileExport {
    /// Caller obtains explicit overwrite approval, e.g. through NSSavePanel.
    public static func copy(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let identity = try FileIdentity.read(source)
        let parent = destination.deletingLastPathComponent()
        let parentIdentity = try DirectoryIdentity.read(parent)
        let temporary = parent.appendingPathComponent(".log-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try SafeFileTransaction.copyAndSync(source, to: temporary)
        try identity.verify(source); try parentIdentity.verify(parent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileSafety.ensureRegular(destination)
            try SafeFileTransaction.replace(temporary, at: destination)
        } else { try SafeFileTransaction.publishExclusive(temporary, to: destination) }
    }
}
