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
            switch operation {
            case .write(let offset, _), .writeCopy(let offset, _, _, _):
                guard offset.isValid else { throw PhotoError("UTC 偏移必須介於 −12:00 與 +14:00，並以 15 分鐘為單位。") }
            case .inspect, .restore: break
            }
            if case .writeCopy(_, _, let destination, let roots) = operation {
                try CopyDestination.validate(destination, roots: roots)
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
                                try write(item: &item, tool: tool, offset: offset, mode: mode, destination: nil, roots: [], cancellation: cancellation)
                            case .writeCopy(let offset, let mode, let destination, let roots):
                                try write(item: &item, tool: tool, offset: offset, mode: mode, destination: destination, roots: roots, cancellation: cancellation)
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
                items = [PhotoItem(url: inputs.first ?? exiftoolURL, status: .failed, detail: error.localizedDescription)]
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
        item: inout PhotoItem, tool: ExifTool, offset: UTCOffset, mode: WriteMode,
        destination: URL?, roots: [URL], cancellation: CancellationToken
    ) throws {
        let fm = FileManager.default
        let (before, warning) = try tool.inspect(item.url, cancellation: cancellation)
        item.metadata = before
        let fields: [(String, String?)] = [
            ("OffsetTimeOriginal", before.offsetOriginal),
            ("OffsetTimeDigitized", before.offsetDigitized),
            ("OffsetTime", before.offsetTime)
        ]
        let requested = fields.filter { mode == .replaceAll || $0.1 == nil }
        let willChange = requested.contains(where: { $0.1 != offset.value })
        guard willChange || destination != nil else {
            item.status = .skipped
            item.detail = "不需要變更；現有時區已保留。" + (warning.isEmpty ? "" : "\n警告：\(warning)")
            return
        }
        if cancellation.isCancelled {
            item.status = .cancelled
            item.detail = "已取消；尚未開始寫入。"
            return
        }
        let target: URL
        if let destination {
            target = try CopyDestination.url(for: item.url, in: destination, roots: roots)
            try CopyDestination.validate(destination, roots: roots)
            try CopyDestination.prepareOutputParent(target.deletingLastPathComponent(), under: destination)
            guard !fm.fileExists(atPath: target.path) else {
                throw PhotoError("輸出目的地已有同名相片；未覆蓋：\(target.path)")
            }
            try FileSafety.ensureWriteCapacity(target, fileSize: before.fileSize, copies: 3, sourceMustBeWritable: false)
        } else {
            target = item.url
            try FileSafety.ensureWriteCapacity(item.url, fileSize: before.fileSize)
        }
        let sourceHash = try FileSafety.hash(item.url)
        let beforeTags = willChange ? try tool.embeddedMetadata(item.url, cancellation: cancellation) : [:]
        let stage = SafeFileTransaction.temporaryPhoto(beside: target)
        defer { try? fm.removeItem(at: stage) }
        try SafeFileTransaction.copyAndSync(item.url, to: stage)
        var stderr = ""
        if willChange {
            // A read-only memory-card source is valid in copy mode. Only the
            // disposable candidate becomes writable; original permissions
            // are restored and verified before publication.
            let attributes = try fm.attributesOfItem(atPath: stage.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try fm.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: stage.path)
            let arguments = ["-charset", "filename=UTF8", "-P", "-overwrite_original_in_place"] +
                requested.map { "-EXIF:\($0.0)=\(offset.value)" } + [stage.path]
            let output = try tool.execute(arguments, timeout: 600)
            guard output.status == 0 else {
                throw PhotoError("候選副本寫入失敗（\(output.status)）；原檔未更動。\n\(output.text)")
            }
            stderr = output.stderr
        }
        let (after, postWarning) = try tool.inspect(stage)
        if willChange {
            var expectedTags = beforeTags
            for (tag, _) in requested {
                let value = try JSONSerialization.data(withJSONObject: offset.value, options: [.fragmentsAllowed])
                expectedTags["ExifIFD:\(tag)"] = String(decoding: value, as: UTF8.self)
            }
            let actualTags = try tool.embeddedMetadata(stage)
            // TIFF's StripOffsets is a byte pointer, not a user-visible photo
            // property. Expanding EXIF may relocate the unchanged image strips.
            // All other readable embedded tags must match exactly.
            if before.fileType == "TIFF" {
                expectedTags["IFD0:StripOffsets"] = actualTags["IFD0:StripOffsets"]
            }
            if before.fileType == "JPEG",
               let oldThumbnailOffset = beforeTags["IFD1:ThumbnailOffset"],
               let newThumbnailOffset = actualTags["IFD1:ThumbnailOffset"],
               oldThumbnailOffset != newThumbnailOffset {
                guard try tool.thumbnailBytes(item.url) == tool.thumbnailBytes(stage) else {
                    throw PhotoError("候選副本的內建縮圖內容變動；原檔未更動，未輸出此張。")
                }
                expectedTags["IFD1:ThumbnailOffset"] = newThumbnailOffset
            }
            guard actualTags == expectedTags else {
                let changed = Set(actualTags.keys).union(expectedTags.keys)
                    .filter { actualTags[$0] != expectedTags[$0] }.sorted().prefix(8).joined(separator: "、")
                throw PhotoError("候選副本有非時區中繼資料變動（\(changed)）；原檔未更動，未輸出此張。")
            }
        }
        let actual = ["OffsetTimeOriginal": after.offsetOriginal, "OffsetTimeDigitized": after.offsetDigitized, "OffsetTime": after.offsetTime]
        for (tag, prior) in fields {
            let expected = requested.contains(where: { $0.0 == tag }) ? offset.value : prior
            guard actual[tag] == expected else { throw PhotoError("候選副本時區驗證失敗：\(tag)；原檔未更動。") }
        }
        guard before.dateTimeOriginal == after.dateTimeOriginal,
              before.createDate == after.createDate,
              before.modifyDate == after.modifyDate, before.dateTags == after.dateTags else {
            throw PhotoError("候選副本拍攝／建立／修改時間變動；原檔未更動。")
        }
        try FileSafety.preserveAndVerifyFileAttributes(from: item.url, to: stage)
        try SafeFileTransaction.syncFile(stage)
        guard try FileSafety.hash(item.url) == sourceHash else {
            throw PhotoError("處理期間原檔被其他程式改動；未提交此張，請重新掃描。")
        }
        var backupName: String?
        if destination == nil {
            let oldest = URL(fileURLWithPath: item.url.path + "_original")
            let backup: URL
            if fm.fileExists(atPath: oldest.path) {
                try FileSafety.ensureRegular(oldest)
                _ = try tool.inspect(oldest, cancellation: cancellation, strictOffsets: false)
                backup = URL(fileURLWithPath: item.url.path + ".before-write-\(UUID().uuidString).backup")
            } else {
                backup = oldest
            }
            let backupStage = backup.deletingLastPathComponent()
                .appendingPathComponent(".photo-timezone-backup-\(UUID().uuidString).backup")
            defer { try? fm.removeItem(at: backupStage) }
            try SafeFileTransaction.copyAndSync(item.url, to: backupStage)
            try SafeFileTransaction.publishExclusive(backupStage, to: backup)
            backupName = backup.lastPathComponent
            guard try FileSafety.hash(item.url) == sourceHash else {
                throw PhotoError("備份完成後原檔被其他程式改動；備份保留，未替換，請重新掃描。")
            }
            try SafeFileTransaction.replace(stage, at: item.url)
        } else {
            try SafeFileTransaction.publishExclusive(stage, to: target)
        }
        if destination == nil {
            item.metadata = after
        } else {
            // The table still describes the unmodified source. Show the
            // generated result separately instead of claiming its offsets
            // are now present on the source photo.
            item.metadata = before
            item.outputURL = target
            item.outputMetadata = after
        }
        item.status = .success
        if let backupName {
            item.detail = "已安全替換並驗證 \(offset.value)；替換前版本保留於 \(backupName)。"
        } else {
            item.detail = willChange ? "已輸出並驗證 \(offset.value) 的副本：\(target.path)；原檔未更動。"
                                     : "原有時區完整，已原樣輸出副本：\(target.path)；原檔未更動。"
        }
        let warnings = [warning, stderr, postWarning].filter { !$0.isEmpty }.joined(separator: "\n")
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
        let backupSize = Int64(try backup.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try FileSafety.ensureWriteCapacity(item.url, fileSize: backupSize, copies: 3, sourceMustBeWritable: false)
        let stage = SafeFileTransaction.temporaryPhoto(beside: item.url)
        defer { try? fm.removeItem(at: stage) }
        try SafeFileTransaction.copyAndSync(backup, to: stage)
        guard try FileSafety.hash(stage) == digest else {
            throw PhotoError("原始備份暫存副本 SHA-256 驗證失敗；未復原。")
        }
        if !fm.fileExists(atPath: item.url.path) {
            try SafeFileTransaction.publishExclusive(stage, to: item.url)
            guard try FileSafety.hash(item.url) == digest else {
                throw PhotoError("遺失檔案重建後驗證失敗；_original 備份仍保留。")
            }
            item.metadata = try tool.inspect(item.url, strictOffsets: false).0
            item.status = .success
            item.detail = "已從 _original 重建遺失檔案並驗證；原始備份仍保留。"
            return
        }
        try FileSafety.ensureRegular(item.url)
        let currentHash = try FileSafety.hash(item.url)
        // Retain the currently edited photo before the atomic replacement.
        let currentCopy = URL(fileURLWithPath: item.url.path + ".before-restore-\(UUID().uuidString).backup")
        let backupStage = currentCopy.deletingLastPathComponent()
            .appendingPathComponent(".photo-timezone-backup-\(UUID().uuidString).backup")
        defer { try? fm.removeItem(at: backupStage) }
        try SafeFileTransaction.copyAndSync(item.url, to: backupStage)
        try SafeFileTransaction.publishExclusive(backupStage, to: currentCopy)
        guard try FileSafety.hash(item.url) == currentHash else {
            throw PhotoError("復原前原檔被其他程式改動；現況副本保留，未執行復原。")
        }
        try SafeFileTransaction.replace(stage, at: item.url)
        guard try FileSafety.hash(item.url) == digest else {
            throw PhotoError("復原後 SHA-256 不符，請檢查原檔與 \(currentCopy.lastPathComponent)。")
        }
        let (metadata, warning) = try tool.inspect(item.url, strictOffsets: false)
        item.metadata = metadata
        item.status = .success
        item.detail = "已從 _original 原子還原並驗證完整檔案；_original 與復原前版本 \(currentCopy.lastPathComponent) 均保留。"
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
