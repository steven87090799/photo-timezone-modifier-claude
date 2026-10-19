import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
@_silgen_name("setxattr") private func linuxSetXattr(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ value: UnsafeRawPointer?, _ size: Int, _ flags: Int32) -> Int32
@_silgen_name("listxattr") private func linuxListXattr(_ path: UnsafePointer<CChar>, _ list: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int
@_silgen_name("getxattr") private func linuxGetXattr(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?, _ size: Int) -> Int
#endif

/// Fast conflict detection, NOT a content digest. mtime and ctime retain nanoseconds.
/// Does not claim protection against a malicious writer or a final path race.
public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let links: UInt64
    public let mode: UInt32

    public static func read(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw PhotoError("Not an accessible regular file (symlinks are not accepted): \(url.path)")
        }
        #if canImport(Darwin)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        return FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
            size: Int64(info.st_size), modifiedSeconds: Int64(modified.tv_sec),
            modifiedNanoseconds: Int64(modified.tv_nsec), changedSeconds: Int64(changed.tv_sec),
            changedNanoseconds: Int64(changed.tv_nsec), links: UInt64(info.st_nlink), mode: UInt32(info.st_mode))
    }

    public func verify(_ url: URL) throws {
        guard try self == Self.read(url) else {
            throw PhotoError("File changed since inspection or during processing; not committed. Rescan: \(url.path)")
        }
    }
}

struct DirectoryIdentity: Equatable, Codable, Sendable {
    let device: UInt64
    let inode: UInt64
    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw PhotoError("Directory was removed, replaced, or became a symlink: \(url.path)")
        }
        return Self(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }
    func verify(_ url: URL) throws {
        guard try self == Self.read(url) else { throw PhotoError("Directory identity changed: \(url.path)") }
    }
}

enum FileSafety {
    static func ensureRegular(_ url: URL) throws { _ = try FileIdentity.read(url) }

    static func ensureWriteCapacity(_ url: URL, fileSize: Int64?, copies: Int64 = 4,
                                    sourceMustBeWritable: Bool = true) throws {
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              !sourceMustBeWritable || (FileManager.default.isWritableFile(atPath: url.path)
                && ((try? FileIdentity.read(url).mode) ?? 0) & 0o222 != 0) else {
            throw PhotoError("原檔或目的資料夾為唯讀；請改用可寫入的獨立副本目的地。")
        }
        let size = try fileSize ?? FileIdentity.read(url).size
        let (bytes, overflow) = max(size, 0).multipliedReportingOverflow(by: copies)
        let (required, overheadOverflow) = bytes.addingReportingOverflow(32 * 1024 * 1024)
        guard !overflow, !overheadOverflow else { throw PhotoError("File size exceeds the safe capacity calculation.") }
        if let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(available) < required {
            throw PhotoError("Insufficient free space for candidate and backups; no original was changed.")
        }
    }

    static func preserveAndVerifyFileAttributes(from source: URL, to candidate: URL) throws {
        let fm = FileManager.default
        let before = try fm.attributesOfItem(atPath: source.path)
        let staged = try fm.attributesOfItem(atPath: candidate.path)
        var requested: [FileAttributeKey: Any] = [:]
        if let permissions = before[.posixPermissions] as? NSNumber,
           permissions != staged[.posixPermissions] as? NSNumber { requested[.posixPermissions] = permissions }
        #if canImport(Darwin)
        if let created = before[.creationDate] as? Date, created != staged[.creationDate] as? Date {
            requested[.creationDate] = created
        }
        #endif
        if !requested.isEmpty { try fm.setAttributes(requested, ofItemAtPath: candidate.path) }
        var originalInfo = stat()
        guard lstat(source.path, &originalInfo) == 0 else { throw PhotoError("Cannot read original file timestamps.") }
        #if canImport(Darwin)
        var times = [originalInfo.st_atimespec, originalInfo.st_mtimespec]
        #else
        var times = [originalInfo.st_atim, originalInfo.st_mtim]
        #endif
        guard utimensat(AT_FDCWD, candidate.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PhotoError("Cannot preserve precise file modification time; original not changed.")
        }
        let original = try FileIdentity.read(source), after = try FileIdentity.read(candidate)
        guard original.modifiedSeconds == after.modifiedSeconds,
              original.modifiedNanoseconds == after.modifiedNanoseconds,
              original.mode & 0o7777 == after.mode & 0o7777 else {
            throw PhotoError("File timestamp precision or permissions could not be preserved on this filesystem.")
        }
        #if canImport(Darwin)
        let attributes = try fm.attributesOfItem(atPath: candidate.path)
        guard before[.creationDate] as? Date == attributes[.creationDate] as? Date else {
            throw PhotoError("File creation time could not be preserved; original not changed.")
        }
        #endif
        let originalAttributes = try extendedAttributes(source)
        let candidateAttributes = try extendedAttributes(candidate)
        var systemManaged: Set<String> = []
        #if canImport(Darwin)
        // Native copies can receive a new quarantine record and provenance for
        // their new inode/process, including when clonefile falls back across
        // volumes. Leave these destination security records untouched: copying
        // the source values back or removing the new records is not appropriate.
        systemManaged = ["com.apple.quarantine", "com.apple.provenance"]
        if let quarantine = originalAttributes["com.apple.quarantine"], !quarantine.isEmpty {
            guard let retained = candidateAttributes["com.apple.quarantine"], !retained.isEmpty else {
                throw PhotoError("候選檔遺失 macOS 隔離標記；原檔保持原狀。")
            }
        }
        #endif
        let differing = Set(originalAttributes.keys).union(candidateAttributes.keys)
            .subtracting(systemManaged)
            .filter { originalAttributes[$0] != candidateAttributes[$0] }.sorted()
        guard differing.isEmpty else {
            throw PhotoError("檔案延伸屬性不一致（\(differing.joined(separator: "、"))）；原檔保持原狀。")
        }
    }

    /// A converted image has new pixel/container bytes, so native file copying
    /// cannot transfer its filesystem metadata. Copy ordinary attributes only
    /// after rejecting attributes that may describe the old file's data format.
    static func preserveConvertedImageAttributes(from source: URL, to candidate: URL) throws {
        let originalIdentity = try FileIdentity.read(source)
        let candidateIdentity = try FileIdentity.read(candidate)
        guard originalIdentity.device != candidateIdentity.device || originalIdentity.inode != candidateIdentity.inode,
              candidateIdentity.links == 1 else {
            throw PhotoError("轉檔輸出必須是與原檔分離、沒有硬連結的獨立檔案。")
        }
        #if canImport(Darwin)
        var sourceInfo = stat(), candidateInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0, lstat(candidate.path, &candidateInfo) == 0 else {
            throw PhotoError("無法核對來源與輸出的檔案旗標；已停止輸出。")
        }
        let transferableFlags = UInt32(UF_HIDDEN | UF_NODUMP)
        let systemFlags = UInt32(UF_TRACKED)
        guard sourceInfo.st_flags & ~(transferableFlags | systemFlags) == 0 else {
            throw PhotoError("來源含有無法安全轉移的鎖定、附加或檔案系統旗標；已停止轉檔，請保留原件。")
        }
        #endif
        let original = try extendedAttributes(source)
        let destination = try extendedAttributes(candidate)
        if let resource = original["com.apple.ResourceFork"], !resource.isEmpty {
            throw PhotoError("來源含有資源分支，可能保存原格式專用資料；無法保證轉檔後完整保留，已停止輸出。請保留原檔。")
        }
        if let compressed = original["com.apple.decmpfs"], !compressed.isEmpty {
            throw PhotoError("來源含有檔案系統壓縮結構，不能套用到轉檔後的影像；已停止輸出，請保留原檔。")
        }
        if let finder = original["com.apple.FinderInfo"], !finder.isEmpty {
            guard finder.count == 32 else {
                throw PhotoError("來源 FinderInfo 結構無法安全解析；已停止轉檔輸出，請保留原檔。")
            }
            func family(_ url: URL) -> String {
                switch url.pathExtension.lowercased() {
                case "jpg", "jpeg": return "jpeg"
                case "tif", "tiff": return "tiff"
                case "heic", "heif": return "heif"
                default: return url.pathExtension.lowercased()
                }
            }
            if finder.prefix(4).contains(where: { $0 != 0 }), family(source) != family(candidate) {
                throw PhotoError("來源 FinderInfo 含原格式的檔案類型；轉成其他格式會造成錯誤標記，已停止輸出。請保留原檔。")
            }
        }
        let security: Set<String> = ["com.apple.quarantine", "com.apple.provenance"]
        for (name, value) in original where !security.contains(name) && destination[name] != value {
            try setExtendedAttribute(name, value: value, on: candidate)
        }
        // Keep destination security records generated by macOS. When an encoder
        // creates a fresh unmarked file, retaining the source quarantine adds a
        // restriction; it never removes or weakens the generated destination one.
        if let quarantine = original["com.apple.quarantine"], !quarantine.isEmpty,
           destination["com.apple.quarantine"]?.isEmpty ?? true {
            try setExtendedAttribute("com.apple.quarantine", value: quarantine, on: candidate)
        }
        try preserveAndVerifyFileAttributes(from: source, to: candidate)
        #if canImport(Darwin)
        try preserveAndVerifyACL(from: source, to: candidate)
        guard lstat(candidate.path, &candidateInfo) == 0 else {
            throw PhotoError("無法再次核對輸出旗標；已停止轉檔。")
        }
        let expectedFlags = (candidateInfo.st_flags & ~transferableFlags) | (sourceInfo.st_flags & transferableFlags)
        if candidateInfo.st_flags != expectedFlags {
            guard chflags(candidate.path, expectedFlags) == 0 else {
                throw PhotoError("無法保留來源的隱藏／備份旗標；已停止轉檔。")
            }
        }
        var flagsAfter = stat()
        guard lstat(candidate.path, &flagsAfter) == 0, flagsAfter.st_flags == expectedFlags else {
            throw PhotoError("轉檔後的檔案旗標不符；已停止輸出。")
        }
        #endif
        try originalIdentity.verify(source)
        let after = try FileIdentity.read(candidate)
        guard after.device == candidateIdentity.device, after.inode == candidateIdentity.inode,
              after.size == candidateIdentity.size, after.links == 1 else {
            throw PhotoError("轉檔輸出在保留檔案屬性時改變；已停止輸出。")
        }
    }

    #if canImport(Darwin)
    private static func preserveAndVerifyACL(from source: URL, to candidate: URL) throws {
        let original = try accessControlList(source)
        let before = try FileManager.default.attributesOfItem(atPath: candidate.path)
        if try accessControlList(candidate) != original {
            let flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_NOFOLLOW)
            guard copyfile(source.path, candidate.path, nil, flags) == 0 else {
                throw PhotoError("無法保留來源的存取控制清單；未接受轉檔輸出，請保留原檔。")
            }
        }
        let after = try FileManager.default.attributesOfItem(atPath: candidate.path)
        guard try accessControlList(candidate) == original,
              before[.ownerAccountID] as? NSNumber == after[.ownerAccountID] as? NSNumber,
              before[.groupOwnerAccountID] as? NSNumber == after[.groupOwnerAccountID] as? NSNumber else {
            throw PhotoError("轉檔後的存取控制或擁有者無法可靠核對；已停止輸出，請保留原檔。")
        }
    }

    private static func accessControlList(_ url: URL) throws -> Data {
        errno = 0
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT for a regular file with no extended ACL.
            // Distinguish that state from a missing/replaced file or a real
            // permission/filesystem error, which must still stop publication.
            if errno == ENOENT { _ = try FileIdentity.read(url); return Data() }
            throw PhotoError("無法可靠讀取來源或輸出的存取控制清單；已停止轉檔。")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var count = 0
        guard let text = acl_to_text(acl, &count), count >= 0, count <= 1024 * 1024 else {
            throw PhotoError("無法可靠解析來源或輸出的存取控制清單；已停止轉檔。")
        }
        defer { acl_free(text) }
        return Data(bytes: text, count: count)
    }
    #endif

    private static func setExtendedAttribute(_ name: String, value: Data, on url: URL) throws {
        let result = value.withUnsafeBytes { bytes in
            #if canImport(Darwin)
            return setxattr(url.path, name, bytes.baseAddress, value.count, 0, XATTR_NOFOLLOW)
            #else
            return url.path.withCString { path in name.withCString { attribute in
                linuxSetXattr(path, attribute, bytes.baseAddress, value.count, 0)
            } }
            #endif
        }
        guard result == 0 else { throw PhotoError("無法完整保留轉檔來源的檔案延伸屬性：\(name)。") }
    }

    #if os(Linux)
    static func copyExtendedAttributes(from source: URL, to destination: URL) throws {
        for (name, data) in try extendedAttributes(source) {
            let result = destination.path.withCString { p in name.withCString { n in
                data.withUnsafeBytes { linuxSetXattr(p, n, $0.baseAddress, data.count, 0) }
            } }
            guard result == 0 else { throw PhotoError("Cannot copy extended attribute: \(name)") }
        }
    }
    #endif

    private static func extendedAttributes(_ url: URL) throws -> [String: Data] {
        let budget = 8 * 1024 * 1024
        func list(_ data: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
            #if canImport(Darwin)
            return listxattr(url.path, data, size, XATTR_NOFOLLOW)
            #else
            return url.path.withCString { linuxListXattr($0, data, size) }
            #endif
        }
        func get(_ name: String, _ data: UnsafeMutableRawPointer?, _ size: Int) -> Int {
            #if canImport(Darwin)
            return getxattr(url.path, name, data, size, 0, XATTR_NOFOLLOW)
            #else
            return url.path.withCString { p in name.withCString { linuxGetXattr(p, $0, data, size) } }
            #endif
        }
        let length = list(nil, 0)
        guard length >= 0, length <= 128 * 1024 else { throw PhotoError("Extended-attribute list unavailable or too large.") }
        if length == 0 { return [:] }
        var names = [CChar](repeating: 0, count: length)
        let actual = names.withUnsafeMutableBufferPointer { list($0.baseAddress, length) }
        guard actual == length else { throw PhotoError("Extended-attribute list changed while reading.") }
        var result: [String: Data] = [:], used = 0
        for raw in names.split(separator: 0) {
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = get(name, nil, 0)
            guard size >= 0, size <= budget - used else { throw PhotoError("Extended attributes exceed the 8 MiB safety budget.") }
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes { get(name, $0.baseAddress, size) }
            guard count == size else { throw PhotoError("Extended attribute changed while reading: \(name)") }
            result[name] = data; used += size
        }
        return result
    }
}
