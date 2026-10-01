import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Every candidate and backup is made in its final directory. The source is
/// never handed to ExifTool: only a validated, durable candidate is published.
enum SafeFileTransaction {
    static func temporaryPhoto(beside destination: URL) -> URL {
        let ext = destination.pathExtension
        return destination.deletingLastPathComponent()
            .appendingPathComponent(".photo-timezone-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    /// A disposable candidate needs no durability flush before modification.
    /// APFS clone avoids copying image bytes; fallback preserves file attributes.
    static func copyCandidate(_ source: URL, to destination: URL) throws {
        let identity = try FileIdentity.read(source)
        #if canImport(Darwin)
        if clonefile(source.path, destination.path, 0) != 0 {
            if errno == EEXIST { throw PhotoError("Candidate path already exists; not overwritten.") }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        #else
        try FileManager.default.copyItem(at: source, to: destination)
        try FileSafety.copyExtendedAttributes(from: source, to: destination)
        #endif
        try identity.verify(source)
        guard try FileIdentity.read(destination).size == identity.size else {
            throw PhotoError("Candidate size mismatch; original not changed.")
        }
    }

    static func copyAndSync(_ source: URL, to destination: URL) throws {
        try copyCandidate(source, to: destination)
        try FileSafety.preserveAndVerifyFileAttributes(from: source, to: destination)
        try syncFile(destination)
    }

    static func publishExclusive(_ temporary: URL, to destination: URL) throws {
        #if canImport(Darwin)
        let result = temporary.path.withCString { from in
            destination.path.withCString { to in
                renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL))
            }
        }
        #else
        // link() publishes without replacing an existing name on Linux. The
        // shipping macOS implementation above uses RENAME_EXCL.
        let result = link(temporary.path, destination.path)
        if result == 0 { _ = unlink(temporary.path) }
        #endif
        guard result == 0 else {
            if errno == EEXIST { throw PhotoError("目的地已有同名檔案，未覆蓋：\(destination.path)") }
            throw PhotoError("無法安全建立檔案 \(destination.lastPathComponent)：\(String(cString: strerror(errno)))")
        }
        do { try syncDirectory(destination.deletingLastPathComponent()) }
        catch { throw PublicationError(destination: destination, message: "檔案已建立，但無法確認磁碟已保存目錄更新；請檢查 \(destination.path)。\(error.localizedDescription)") }
    }

    static func replace(_ temporary: URL, at destination: URL) throws {
        let result = temporary.path.withCString { from in
            destination.path.withCString { to in rename(from, to) }
        }
        guard result == 0 else {
            throw PhotoError("無法替換原檔；備份仍保留。\(String(cString: strerror(errno)))")
        }
        do { try syncDirectory(destination.deletingLastPathComponent()) }
        catch { throw PublicationError(destination: destination, message: "原檔已替換，但無法確認磁碟已保存目錄更新；備份仍保留，請先檢查 \(destination.path)。\(error.localizedDescription)") }
    }

    static func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw PhotoError("無法同步檔案到磁碟：\(url.lastPathComponent)") }
        defer { close(fd) }
        // F_FULLFSYNC requests that macOS flush drive caches as well. Some
        // external filesystems don't implement it; regular fsync is required.
        #if canImport(Darwin)
        let synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
        #else
        let synced = fsync(fd) == 0
        #endif
        if !synced {
            throw PhotoError("磁碟同步失敗：\(url.lastPathComponent)（\(String(cString: strerror(errno)))）")
        }
    }

    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw PhotoError("無法開啟目的資料夾進行同步。") }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw PhotoError("無法同步目的資料夾到磁碟（\(String(cString: strerror(errno)))）。")
        }
    }
}

/// A copy job preserves the selected directory's name and relative tree.
/// Explicitly selected files go directly under the chosen output folder.
public enum CopyDestination {
    public static func validate(_ destination: URL, roots: [URL]) throws {
        guard !roots.isEmpty else { throw PhotoError("尚未選取來源相片或資料夾。") }
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              FileManager.default.isWritableFile(atPath: destination.path) else {
            throw PhotoError("輸出目的地必須是可寫入的一般資料夾。")
        }
        for root in roots {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard !contains(root, destination), !contains(destination, root) else {
                    throw PhotoError("輸出目的地不可位於來源資料夾內，也不可包含來源資料夾；請選另一個獨立資料夾。")
                }
            } else if contains(destination, root) {
                throw PhotoError("輸出目的地不可包含選取的原檔；請選另一個資料夾。")
            }
        }
    }

    static func prepareOutputParent(_ parent: URL, under destination: URL) throws {
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(root, parent), parent.path != root.path else {
            if parent.path == root.path { return }
            throw PhotoError("輸出路徑不在選定的目的資料夾內。")
        }
        let relative = String(parent.path.dropFirst(root.path.count + 1))
        var cursor = root
        for part in relative.split(separator: "/") {
            cursor.appendPathComponent(String(part), isDirectory: true)
            var status = stat()
            if lstat(cursor.path, &status) == 0 {
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    throw PhotoError("輸出路徑含有非資料夾或符號連結：\(cursor.path)")
                }
            } else if errno == ENOENT {
                try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false)
                try SafeFileTransaction.syncDirectory(cursor.deletingLastPathComponent())
            } else {
                throw PhotoError("無法檢查輸出資料夾：\(cursor.path)")
            }
        }
        let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolvedDestination, resolvedParent),
              FileManager.default.isWritableFile(atPath: resolvedParent.path) else {
            throw PhotoError("輸出子資料夾離開選定的目的地或無法寫入；未輸出此張。")
        }
    }

    static func url(for source: URL, in destination: URL, roots: [URL]) throws -> URL {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let sorted = roots.map(\.standardizedFileURL).sorted { $0.path.count < $1.path.count }
        for root in sorted {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
               isDirectory.boolValue, contains(root, source), root.path != source.path {
                let relative = String(source.path.dropFirst(root.path.count + 1))
                return destination.appendingPathComponent(root.lastPathComponent, isDirectory: true)
                    .appendingPathComponent(relative)
            }
        }
        guard sorted.contains(where: { $0.path == source.path }) else {
            throw PhotoError("來源檔案已不在預覽時選取的範圍，未輸出。")
        }
        return destination.appendingPathComponent(source.lastPathComponent)
    }

    static func contains(_ directory: URL, _ child: URL) -> Bool {
        child.path == directory.path || child.path.hasPrefix(directory.path + "/")
    }
}

/// A failure AFTER publication is not an ordinary retryable write failure.
struct PublicationError: LocalizedError {
    let destination: URL
    let message: String
    var errorDescription: String? { message }
}
