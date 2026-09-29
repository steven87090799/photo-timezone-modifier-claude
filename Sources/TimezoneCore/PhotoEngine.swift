import Foundation
import Darwin

/// The entire pipeline runs off the main actor. Reads use bounded batches;
/// writes receive one path at a time and are never interrupted mid-write.
public struct PhotoEngine: Sendable {
    public let exiftoolURL: URL
    private let logDirectory: URL?
    public init(exiftoolURL: URL, logDirectory: URL? = nil) {
        self.exiftoolURL = exiftoolURL
        self.logDirectory = logDirectory
    }

    public func run(
        inputs: [URL], recursive: Bool, operation: JobOperation,
        cancellation: CancellationToken, inspectedFilesOnly: Bool = false,
        onEvent: @escaping @Sendable (JobEvent) -> Void
    ) async {
        await Task.detached(priority: .userInitiated) {
            self.runSync(inputs: inputs, recursive: recursive, operation: operation, cancellation: cancellation, inspectedFilesOnly: inspectedFilesOnly, onEvent: onEvent)
        }.value
    }

    private func runSync(
        inputs: [URL], recursive: Bool, operation: JobOperation,
        cancellation: CancellationToken, inspectedFilesOnly: Bool, onEvent: @escaping @Sendable (JobEvent) -> Void
    ) {
        let fm = FileManager.default
        let tool = ExifTool(url: exiftoolURL)
        var items: [PhotoItem] = []
        var journal: Journal?
        var generalError: String?
        var jobLock: JobLock?
        defer { jobLock?.release() }
        do {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("PhotoTimezone", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            // Prevent two copies of this app from mutating the same files.
            jobLock = try JobLock(url: support.appendingPathComponent("job.lock"))
            onEvent(.phase("確認內建 ExifTool…"))
            try tool.validateVersion()
            if case .write(let offset, _) = operation, !offset.isValid {
                throw PhotoError("UTC 偏移必須介於 −12:00 與 +14:00，並以 15 分鐘為單位。")
            }
            journal = try Journal(directory: logDirectory ?? support.appendingPathComponent("Logs"), operation: operation.label)
            onEvent(.phase("掃描檔案與資料夾…"))
            items = FileDiscovery.collect(inputs: inputs, recursive: recursive, cancellation: cancellation,
                                          allowDirectories: !inspectedFilesOnly) { onEvent(.phase($0)) }
            onEvent(.discovered(items))
            var inspectionCache: [String: Result<(PhotoMetadata, String), Error>] = [:]
            for index in items.indices {
                var item = items[index]
                let canRecoverMissing: Bool
                if case .restore = operation {
                    canRecoverMissing = item.status == .failed && !fm.fileExists(atPath: item.url.path)
                        && FileDiscovery.extensions.contains(item.url.pathExtension.lowercased())
                        && fm.fileExists(atPath: item.url.path + "_original")
                } else { canRecoverMissing = false }
                if item.status == .pending || canRecoverMissing {
                    if cancellation.isCancelled {
                        item.status = .cancelled
                        item.detail = "已取消；未修改。"
                    } else {
                        onEvent(.phase("\(operation.label) \(index + 1) / \(items.count)：\(item.url.lastPathComponent)"))
                        do {
                            if !canRecoverMissing { try FileSafety.ensureRegular(item.url) }
                            switch operation {
                            case .inspect:
                                if inspectionCache[item.url.path] == nil {
                                    let batch = items[index..<min(index + ExifTool.inspectionBatchSize, items.count)]
                                        .filter { $0.status == .pending }.map(\.url)
                                    do {
                                        inspectionCache = try tool.inspectBatch(batch, cancellation: cancellation)
                                    } catch is CancellationError {
                                        throw CancellationError()
                                    } catch {
                                        // A disappeared/changed file or malformed batch must not
                                        // prevent unrelated photos from being inspected safely.
                                        inspectionCache = [:]
                                    }
                                }
                                let (metadata, warning): (PhotoMetadata, String)
                                if let cached = inspectionCache.removeValue(forKey: item.url.path) {
                                    (metadata, warning) = try cached.get()
                                } else {
                                    (metadata, warning) = try tool.inspect(item.url, cancellation: cancellation)
                                }
                                item.metadata = metadata
                                item.status = .ready
                                item.detail = metadata.missingOffsets ? "有缺漏時區標籤。" : "三個時區標籤均已存在。"
                                if !warning.isEmpty { item.detail += "\n警告：\(warning)" }
                            case .write(let offset, let mode):
                                try write(item: &item, tool: tool, offset: offset, mode: mode, cancellation: cancellation)
                            case .restore:
                                try restore(item: &item, tool: tool, cancellation: cancellation)
                            }
                        } catch is CancellationError {
                            item.status = .cancelled
                            item.detail = "已取消讀取；未寫入。"
                        } catch {
                            item.status = .failed
                            item.detail = error.localizedDescription
                        }
                    }
                }
                items[index] = item
                // Persist the result before starting the next file. If logging
                // fails, stop all further writes rather than losing the audit.
                try journal?.append(item)
                onEvent(.updated(item, completed: index + 1, total: items.count))
            }
        } catch {
            generalError = error.localizedDescription
            if items.isEmpty {
                items = [PhotoItem(url: exiftoolURL, status: .failed, detail: error.localizedDescription)]
                onEvent(.discovered(items))
            } else {
                for index in items.indices where items[index].status == .pending {
                    items[index].status = .cancelled
                    items[index].detail = "工作中止：\(error.localizedDescription)"
                }
                // Re-publish the complete state, including the last completed
                // file if its journal write failed.
                onEvent(.discovered(items))
            }
        }
        let succeeded = items.filter { $0.status == .success || $0.status == .ready }.count
        let failed = items.filter { $0.status == .failed }.count
        let skipped = items.filter { $0.status == .skipped }.count
        let cancelled = items.filter { $0.status == .cancelled }.count
        let prefix = cancellation.isCancelled ? "已停止" : (generalError == nil ? "完成" : "工作中止")
        var message = "\(operation.label)\(prefix)：成功 \(succeeded)、略過 \(skipped)、失敗 \(failed)、取消 \(cancelled)。"
        if items.isEmpty { message += " 未找到符合格式的檔案。" }
        if cancellation.isCancelled { message += " 掃描若未完成，總數僅包含已找到的項目。" }
        if let generalError { message += "\n\(generalError)" }
        do { try journal?.finish(message) } catch { message += "\n紀錄儲存失敗：\(error.localizedDescription)" }
        onEvent(.finished(JobSummary(
            total: items.count, succeeded: succeeded, skipped: skipped, failed: failed,
            cancelled: cancelled, logURL: journal?.url, message: message
        )))
    }

    private func write(
        item: inout PhotoItem, tool: ExifTool, offset: UTCOffset, mode: WriteMode, cancellation: CancellationToken
    ) throws {
        let (before, warning) = try tool.inspect(item.url, cancellation: cancellation)
        item.metadata = before
        let fields: [(String, String?)] = [
            ("OffsetTimeOriginal", before.offsetOriginal),
            ("OffsetTimeDigitized", before.offsetDigitized),
            ("OffsetTime", before.offsetTime)
        ]
        let requested = fields.filter { mode == .replaceAll || $0.1 == nil }
        guard requested.contains(where: { $0.1 != offset.value }) else {
            item.status = .skipped
            item.detail = "不需要變更；現有時區已保留。" + (warning.isEmpty ? "" : "\n警告：\(warning)")
            return
        }
        if cancellation.isCancelled {
            item.status = .cancelled
            item.detail = "已取消；尚未開始寫入。"
            return
        }
        let backup = URL(fileURLWithPath: item.url.path + "_original")
        // ExifTool never replaces its original backup. Validate an existing
        // backup instead of assuming any file with this name is a safe copy.
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileSafety.ensureRegular(backup)
            _ = try tool.inspect(backup, cancellation: cancellation, strictOffsets: false)
        }
        if cancellation.isCancelled { throw CancellationError() }
        try FileSafety.ensureWriteCapacity(item.url, fileSize: before.fileSize)
        let arguments = ["-charset", "filename=UTF8", "-P"] +
            requested.map { "-EXIF:\($0.0)=\(offset.value)" } + [item.url.path]
        // Deliberately omit -overwrite_original: ExifTool preserves _original.
        let output = try tool.execute(arguments)
        guard output.status == 0 else {
            throw PhotoError("寫入失敗（\(output.status)）。原檔備份若已建立，位於 \(backup.lastPathComponent)。\n\(output.text)")
        }
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw PhotoError("寫入後未找到原檔備份，請先檢查檔案；不會標示為成功。")
        }
        let (after, postWarning) = try tool.inspect(item.url)
        let actual = ["OffsetTimeOriginal": after.offsetOriginal, "OffsetTimeDigitized": after.offsetDigitized, "OffsetTime": after.offsetTime]
        for (tag, prior) in fields {
            let expected = requested.contains(where: { $0.0 == tag }) ? offset.value : prior
            guard actual[tag] == expected else { throw PhotoError("寫入後驗證失敗：\(tag)。可從 _original 備份復原。") }
        }
        guard before.dateTimeOriginal == after.dateTimeOriginal,
              before.createDate == after.createDate,
              before.modifyDate == after.modifyDate, before.dateTags == after.dateTags else {
            throw PhotoError("拍攝／建立／修改時間驗證失敗；請從 _original 備份復原。")
        }
        item.metadata = after
        item.status = .success
        item.detail = "已寫入並驗證 \(offset.value)；保留原檔備份：\(backup.lastPathComponent)"
        let warnings = [warning, output.stderr, postWarning].filter { !$0.isEmpty }.joined(separator: "\n")
        if !warnings.isEmpty { item.detail += "\n警告：\(warnings)" }
    }

    private func restore(item: inout PhotoItem, tool: ExifTool, cancellation: CancellationToken) throws {
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: item.url.path + "_original")
        guard fm.fileExists(atPath: backup.path) else {
            item.status = .skipped
            item.detail = "沒有 _original 備份，未變更。"
            return
        }
        try FileSafety.ensureRegular(backup)
        _ = try tool.inspect(backup, cancellation: cancellation, strictOffsets: false)
        let digest = try FileSafety.hash(backup)
        if cancellation.isCancelled {
            item.status = .cancelled
            item.detail = "已取消；未復原。"
            return
        }
        if !fm.fileExists(atPath: item.url.path) {
            // copyItem refuses an existing destination, including a dangling
            // symlink; never overwrite a file created after the discovery.
            try fm.copyItem(at: backup, to: item.url)
            guard try FileSafety.hash(item.url) == digest else {
                throw PhotoError("遺失檔案重建後驗證失敗；_original 備份仍保留。")
            }
            item.metadata = try tool.inspect(item.url, strictOffsets: false).0
            item.status = .success
            item.detail = "已從 _original 重建遺失檔案並驗證；原始備份仍保留。"
            return
        }
        // Also retain the current edited photo so restoration itself is
        // reversible. The .backup suffix excludes this from future scans.
        let currentCopy = URL(fileURLWithPath: item.url.path + ".before-restore-\(UUID().uuidString).backup")
        try FileSafety.ensureWriteCapacity(item.url, fileSize: nil)
        try fm.copyItem(at: item.url, to: currentCopy)
        guard try FileSafety.hash(item.url) == FileSafety.hash(currentCopy) else {
            throw PhotoError("復原前的現況副本驗證失敗；未執行復原。")
        }
        let output = try tool.execute(["-charset", "filename=UTF8", "-restore_original", item.url.path])
        guard output.status == 0 else {
            throw PhotoError("復原失敗（\(output.status)）。目前版本已另存 \(currentCopy.lastPathComponent)。\n\(output.text)")
        }
        guard try FileSafety.hash(item.url) == digest else {
            throw PhotoError("復原後 SHA-256 不符，請檢查原檔與 \(currentCopy.lastPathComponent)。")
        }
        let (metadata, warning) = try tool.inspect(item.url, strictOffsets: false)
        item.metadata = metadata
        item.status = .success
        item.detail = "已還原 _original 並驗證完整檔案；復原前版本保留於 \(currentCopy.lastPathComponent)。"
        if !warning.isEmpty { item.detail += "\n警告：\(warning)" }
    }
}

private final class Journal {
    let url: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    init(directory: URL, operation: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("job-\(UUID().uuidString).jsonl")
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PhotoError("無法建立處理紀錄；尚未修改照片。")
        }
        handle = try FileHandle(forWritingTo: url)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try line(["operation": operation, "startedAt": ISO8601DateFormatter().string(from: Date()), "engine": EngineResources.version])
    }
    deinit { try? handle.close() }
    func append(_ item: PhotoItem) throws { try line(item) }
    func finish(_ message: String) throws { try line(["summary": message, "finishedAt": ISO8601DateFormatter().string(from: Date())]) }
    private func line<T: Encodable>(_ value: T) throws {
        try handle.write(contentsOf: encoder.encode(value) + Data([0x0a]))
        try handle.synchronize()
    }
}

private final class JobLock {
    private var descriptor: Int32
    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PhotoError("無法建立工作鎖。") }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(descriptor)
            descriptor = -1
            throw PhotoError("另一個相片時區修改器正在處理；請等候它完成。")
        }
    }
    func release() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
    deinit { release() }
}
