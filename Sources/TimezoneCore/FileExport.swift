import Foundation

public enum FileExport {
    /// Preserve filesystem metadata separately from the converted image's
    /// embedded EXIF/XMP verification. Format-bound attributes are fail-closed.
    public static func preserveConvertedImageAttributes(from source: URL, to destination: URL) throws {
        try FileSafety.preserveConvertedImageAttributes(from: source, to: destination)
    }

    /// Archive exports always create a new name. A private staging directory
    /// gives cleanup ownership without trusting a randomly named existing file.
    public static func copyExclusive(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw PhotoError("輸出位置不可與來源相同；請選擇新的檔案名稱或資料夾。")
        }
        let identity = try FileIdentity.read(source)
        let parent = destination.deletingLastPathComponent()
        let parentIdentity = try DirectoryIdentity.read(parent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw PhotoError("輸出位置已有同名檔案；請選擇新的名稱，既有檔案未覆蓋：\(destination.lastPathComponent)")
        }
        try FileSafety.ensureWriteCapacity(destination, fileSize: identity.size, copies: 1,
                                           sourceMustBeWritable: false)
        let directory = parent.appendingPathComponent(".photo-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("payload")
        try SafeFileTransaction.copyAndSync(source, to: temporary)
        guard try SafeFileTransaction.contentsAreIdentical(source, temporary) else {
            throw PhotoError("輸出候選檔與已驗證結果的位元組不符；未建立輸出。")
        }
        try identity.verify(source)
        try parentIdentity.verify(parent)
        try SafeFileTransaction.publishExclusive(temporary, to: destination)
        guard try SafeFileTransaction.contentsAreIdentical(source, destination) else {
            throw PublicationError(destination: destination,
                message: "輸出已建立，但讀回位元組驗證失敗；請保留來源並檢查 \(destination.path)。")
        }
        try identity.verify(source)
    }

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
