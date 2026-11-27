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
        let entries: [URL]
    }

    private let capacity: Int
    private var cache: [String: CachedDirectory] = [:]
    private var recent: [String] = []
    private static let extensions: Set<String> = ["xmp", "on1", "acr"]

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func find(beside photo: URL) throws -> [URL] {
        let candidates = try contents(beside: photo).sidecars
        let stem = Self.key(photo.deletingPathExtension().lastPathComponent)
        let fullName = Self.key(photo.lastPathComponent)
        var result: [URL] = []
        var seenFiles = Set<String>()
        for url in (candidates[stem] ?? []) + (candidates[fullName] ?? []) {
            // Matching symlinks, directories and unreadable entries make GPS
            // absence unknown; never discard them before FileIdentity checks.
            _ = try FileIdentity.read(url)
            // Different supported sidecar names remain distinct assets even
            // when the original names happen to be hard links to one inode.
            guard seenFiles.insert(url.standardizedFileURL.path).inserted else { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    func requireExclusiveXMP(_ sidecars: [URL], beside photo: URL) throws {
        let xmpNames = Set(sidecars.filter { $0.pathExtension.lowercased() == "xmp" }
            .map { Self.key($0.deletingPathExtension().lastPathComponent) })
        guard !xmpNames.isEmpty else { return }
        let entries = try contents(beside: photo).entries
        for entry in entries where !entry.hasDirectoryPath {
            // A missing photo with a canonical backup can still own an XMP.
            let candidate = entry.path.hasSuffix("_original")
                ? URL(fileURLWithPath: String(entry.path.dropLast("_original".count))) : entry
            guard FileDiscovery.extensions.contains(candidate.pathExtension.lowercased()),
                  !candidate.standardizedFileURL.path.utf8.elementsEqual(photo.standardizedFileURL.path.utf8) else { continue }
            if xmpNames.contains(Self.key(candidate.lastPathComponent)) ||
                xmpNames.contains(Self.key(candidate.deletingPathExtension().lastPathComponent)) {
                if let current = try? FileIdentity.read(photo), let other = try? FileIdentity.read(candidate),
                   current.links == 1, current.device == other.device, current.inode == other.inode { continue }
                throw PhotoError("多張照片共用同一個 XMP sidecar，無法判定歸屬：\(candidate.lastPathComponent)。未寫入。")
            }
        }
    }

    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }

    private func contents(beside photo: URL) throws -> CachedDirectory {
        let directory = photo.deletingLastPathComponent().standardizedFileURL
        let stamp = try DirectoryStamp.read(directory)
        if let cached = cache[directory.path], cached.stamp == stamp {
            touch(directory.path)
            return cached
        }
        return try refresh(directory)
    }

    private func refresh(_ directory: URL) throws -> CachedDirectory {
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
                let base = Self.key(url.deletingPathExtension().lastPathComponent)
                sidecars[base, default: []].append(url.standardizedFileURL)
            }
            let after = try DirectoryStamp.read(directory)
            guard before == after else { continue }
            let result = CachedDirectory(stamp: after, sidecars: sidecars, entries: urls)
            cache[directory.path] = result
            touch(directory.path)
            trim()
            return result
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
