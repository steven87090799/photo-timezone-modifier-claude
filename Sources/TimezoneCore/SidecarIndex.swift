import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Job-scoped sidecar directory index. Each directory is enumerated once and
/// reused while its inode/mtime/ctime stamp is unchanged. This reduces NAS/SMB
/// path probes while still refreshing when files are added, removed or renamed.
final class SidecarIndex {
    private struct DirectoryStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(_ url: URL) throws -> Self {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw PhotoError("Sidecar directory was removed, replaced, or became a symlink: \(url.path)")
            }
            #if canImport(Darwin)
            let modified = info.st_mtimespec, changed = info.st_ctimespec
            #else
            let modified = info.st_mtim, changed = info.st_ctim
            #endif
            return Self(
                device: UInt64(truncatingIfNeeded: info.st_dev),
                inode: UInt64(info.st_ino),
                modifiedSeconds: Int64(modified.tv_sec),
                modifiedNanoseconds: Int64(modified.tv_nsec),
                changedSeconds: Int64(changed.tv_sec),
                changedNanoseconds: Int64(changed.tv_nsec)
            )
        }
    }

    private struct CachedDirectory {
        let stamp: DirectoryStamp
        let sidecars: [String: [URL]]
    }

    private let capacity: Int
    private var cache: [String: CachedDirectory] = [:]
    private var recent: [String] = []
    private static let extensions: Set<String> = ["xmp", "on1", "acr"]

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func find(beside photo: URL) throws -> [URL] {
        let directory = photo.deletingLastPathComponent().standardizedFileURL
        let stamp = try DirectoryStamp.read(directory)
        let candidates: [String: [URL]]
        if let cached = cache[directory.path], cached.stamp == stamp {
            candidates = cached.sidecars
            touch(directory.path)
        } else {
            candidates = try refresh(directory)
        }

        let stem = photo.deletingPathExtension().lastPathComponent.lowercased()
        let fullName = photo.lastPathComponent.lowercased()
        var result: [URL] = []
        var seenFiles = Set<String>()
        for url in (candidates[stem] ?? []) + (candidates[fullName] ?? []) {
            // Matching symlinks, directories and unreadable entries make GPS
            // absence unknown; never discard them before FileIdentity checks.
            let identity = try FileIdentity.read(url)
            guard seenFiles.insert("\(identity.device):\(identity.inode)").inserted else { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    private func refresh(_ directory: URL) throws -> [String: [URL]] {
        let fm = FileManager.default
        for _ in 0..<2 {
            let before = try DirectoryStamp.read(directory)
            let urls = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            var sidecars: [String: [URL]] = [:]
            for url in urls where Self.extensions.contains(url.pathExtension.lowercased()) {
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                sidecars[base, default: []].append(url.standardizedFileURL)
            }
            let after = try DirectoryStamp.read(directory)
            guard before == after else { continue }
            cache[directory.path] = CachedDirectory(stamp: after, sidecars: sidecars)
            touch(directory.path)
            trim()
            return sidecars
        }
        throw PhotoError("Sidecar directory changed while it was being indexed. Rescan before retrying.")
    }

    private func touch(_ path: String) {
        recent.removeAll { $0 == path }
        recent.append(path)
    }

    private func trim() {
        while recent.count > capacity {
            let oldest = recent.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}

enum SidecarSupport {
    static func verifyUnchanged(_ inspected: [URL], beside photo: URL, index: SidecarIndex) throws {
        guard Set(try index.find(beside: photo).map(\.path)) == Set(inspected.map(\.path)) else {
            throw PhotoError("Sidecar set changed during processing; photo was not published. Rescan before retrying.")
        }
    }

    static func verifyUnchanged(_ inspected: [URL], beside photo: URL) throws {
        try verifyUnchanged(inspected, beside: photo, index: SidecarIndex(capacity: 1))
    }

    static func find(beside photo: URL, index: SidecarIndex) throws -> [URL] {
        try index.find(beside: photo)
    }

    static func find(beside photo: URL) throws -> [URL] {
        try SidecarIndex(capacity: 1).find(beside: photo)
    }
}
