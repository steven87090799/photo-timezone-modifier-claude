import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
        expectedIdentities: [String: FileIdentity] = [:],
        onEvent: @escaping @Sendable (JobEvent) -> Void
    ) async {
        await Task.detached(priority: .userInitiated) {
            self.runSync(inputs: inputs, recursive: recursive, operation: operation, cancellation: cancellation, inspectedFilesOnly: inspectedFilesOnly, expectedIdentities: expectedIdentities, onEvent: onEvent)
        }.value
    }

    private func runSync(
        inputs: [URL], recursive: Bool, operation: JobOperation,
        cancellation: CancellationToken, inspectedFilesOnly: Bool, expectedIdentities: [String: FileIdentity], onEvent: @escaping @Sendable (JobEvent) -> Void
    ) {
        let fm = FileManager.default
        let tool = ExifTool(url: exiftoolURL, persistent: true)
        let sidecarIndex = SidecarIndex()
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
            case .write(let offset, _, _), .writeCopy(let offset, _, _, _, _):
                guard offset.isValid else { throw PhotoError("UTC 偏移必須介於 −12:00 與 +14:00，並以 15 分鐘為單位。") }
            case .addGPS, .addGPSCopy, .inspect, .restore:
                break
            }
            let plan: DestinationPlan?
            switch operation {
            case .writeCopy(_, _, let destination, let roots, _),
                 .addGPSCopy(_, let destination, let roots, _):
                plan = try DestinationPlan(destination: destination, roots: roots)
            default:
                plan = nil
            }
            let store = try TransactionStore(directory: (logDirectory ?? support).appendingPathComponent("Transactions"))
            let pending = try store.unfinished()
            let blocked = Set(pending.flatMap { [$0.source.path, $0.target.path] })
            journal = try Journal(directory: logDirectory ?? support.appendingPathComponent("Logs"), operation: operation.label)
            onEvent(.phase("掃描檔案與資料夾…"))
            items = FileDiscovery.collect(inputs: inputs, recursive: recursive, cancellation: cancellation,
                                          allowDirectories: !inspectedFilesOnly) { onEvent(.phase($0)) }
            onEvent(.discovered(items))
            var inspectionCache: [String: Result<(PhotoMetadata, String), Error>] = [:]
            var inspectionIdentities: [String: FileIdentity] = [:]
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
                            if !canRecoverMissing {
                                try FileSafety.ensureRegular(item.url)
                                // A rescan establishes a fresh identity. Only a
                                // mutation must match the previously approved preview.
                                if case .inspect = operation {} else {
                                    try expectedIdentities[item.url.path]?.verify(item.url)
                                }
                            }
                            if case .inspect = operation {} else if blocked.contains(item.url.path) {
                                item.publicationUnconfirmed = true
                                throw PhotoError("Unfinished transaction requires review; automatic retry is blocked. See \(store.active.path)")
                            }
                            switch operation {
                            case .inspect:
                                if inspectionCache[item.url.path] == nil {
                                    let batch = items[index..<min(index + ExifTool.inspectionBatchSize, items.count)]
                                        .filter { $0.status == .pending }.map(\.url)
                                    do {
                                        inspectionIdentities = try Dictionary(uniqueKeysWithValues: batch.map { ($0.path, try FileIdentity.read($0)) })
                                        inspectionCache = try autoreleasepool {
                                            try tool.inspectBatch(batch, cancellation: cancellation)
                                        }
                                    } catch is CancellationError {
                                        throw CancellationError()
                                    } catch {
                                        // A disappeared/changed file or malformed batch must not
                                        // prevent unrelated photos from being inspected safely.
                                        inspectionCache = [:]
                                        inspectionIdentities = [:]
                                    }
                                }
                                let (metadata, warning): (PhotoMetadata, String)
                                let identity: FileIdentity
                                if let cached = inspectionCache.removeValue(forKey: item.url.path) {
                                    (metadata, warning) = try cached.get()
                                    guard let captured = inspectionIdentities.removeValue(forKey: item.url.path) else {
                                        throw PhotoError("Inspection identity unavailable; please rescan.")
                                    }
                                    identity = captured
                                } else {
                                    identity = try FileIdentity.read(item.url)
                                    (metadata, warning) = try autoreleasepool {
                                        try tool.inspect(item.url, cancellation: cancellation)
                                    }
                                }
                                var diagnosed = metadata
                                for sidecar in try SidecarSupport.find(beside: item.url, index: sidecarIndex) where sidecar.pathExtension.lowercased() == "xmp" {
                                    let read = try tool.readSidecar(sidecar, cancellation: cancellation)
                                    diagnosed.sidecarGPSDetected = diagnosed.sidecarGPSDetected || read.hasGPS
                                    diagnosed.gpsSafetyUncertain = diagnosed.gpsSafetyUncertain || !read.gpsCheckReliable
                                    diagnosed.compatibilityIssues += read.issues(for: metadata)
                                }
                                diagnosed.compatibilityIssues = Array(Set(diagnosed.compatibilityIssues)).sorted()
                                try identity.verify(item.url)
                                item.metadata = diagnosed
                                item.sourceIdentity = identity
                                item.publicationUnconfirmed = blocked.contains(item.url.path)
                                item.status = .ready
                                item.detail = metadata.missingOffsets ? "尚有 EXIF 時區欄位缺漏。" : "三個 EXIF 時區欄位已齊。"
                                if item.publicationUnconfirmed { item.detail += "\nUnfinished transaction requires manual review; do not retry automatically." }
                                if !warning.isEmpty { item.detail += "\n警告：\(warning)" }
                            case .write(let offset, let mode, let options):
                                try autoreleasepool {
                                    try write(item: &item, tool: tool, offset: offset, mode: mode, options: options, plan: nil, store: store, sidecarIndex: sidecarIndex, cancellation: cancellation)
                                }
                            case .writeCopy(let offset, let mode, _, _, let options):
                                try autoreleasepool {
                                    try write(item: &item, tool: tool, offset: offset, mode: mode, options: options, plan: plan, store: store, sidecarIndex: sidecarIndex, cancellation: cancellation)
                                }
                            case .addGPS(let location, let options):
                                try autoreleasepool {
                                    try writeGPS(item: &item, tool: tool, location: location, options: options,
                                                 plan: nil, store: store, sidecarIndex: sidecarIndex, cancellation: cancellation)
                                }
                            case .addGPSCopy(let location, _, _, let options):
                                try autoreleasepool {
                                    try writeGPS(item: &item, tool: tool, location: location, options: options,
                                                 plan: plan, store: store, sidecarIndex: sidecarIndex, cancellation: cancellation)
                                }
                            case .restore:
                                try restore(item: &item, tool: tool, store: store, cancellation: cancellation)
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
                // Full metadata JSON causes many short-lived allocations.
                // Return empty malloc pages periodically during long jobs;
                // this does not discard live catalogue data or image files.
                if index % 16 == 15 { releaseUnusedPages() }
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
        releaseUnusedPages()
    }

    private func write(
        item: inout PhotoItem, tool: ExifTool, offset: UTCOffset, mode: WriteMode, options: WriteOptions,
        plan: DestinationPlan?, store: TransactionStore, sidecarIndex: SidecarIndex, cancellation: CancellationToken
    ) throws {
        let fm = FileManager.default
        let sourceIdentity = try FileIdentity.read(item.url)
        if plan == nil, sourceIdentity.links > 1 {
            throw PhotoError("Original has hard links. Use copy mode to avoid breaking linked-file semantics.")
        }
        let originalSnapshot = try tool.snapshot(item.url, cancellation: cancellation)
        var before = originalSnapshot.metadata
        item.metadata = before
        try sourceIdentity.verify(item.url)
        try TimeValidation.validateForWrite(before, mode: mode)
        let allFields: [(String, String?)] = [
            ("OffsetTimeOriginal", before.offsetOriginal),
            ("OffsetTimeDigitized", before.offsetDigitized), ("OffsetTime", before.offsetTime)
        ]
        let requested = allFields.filter { (mode == .replaceAll || $0.1 == nil) && $0.1 != offset.value }
        let assignments = requested.map { ($0.0, offset.value) }
        let sidecars = try SidecarSupport.find(beside: item.url, index: sidecarIndex)
        var notices: [String] = []
        let sidecarReads = try sidecars.filter { $0.pathExtension.lowercased() == "xmp" }
            .map { try tool.readSidecar($0, cancellation: cancellation) }
        before.compatibilityIssues = Array(Set(before.compatibilityIssues + sidecarReads.flatMap { $0.issues(for: before) })).sorted()
        item.metadata = before
        if !sidecars.isEmpty {
            notices.append("Sidecars detected: \(sidecars.map(\.lastPathComponent).joined(separator: ", ")). No sidecar dates are rewritten.")
        }
        if requested.isEmpty && plan == nil {
            try sourceIdentity.verify(item.url)
            item.status = .skipped
            item.detail = "No offset change required; existing values were retained."
            if !notices.isEmpty || !before.compatibilityIssues.isEmpty { item.detail += "\n" + (notices + before.compatibilityIssues).joined(separator: "\n") }
            return
        }
        if cancellation.isCancelled { throw CancellationError() }
        let target = try plan?.output(for: item.url) ?? item.url
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        let parentIdentity = try DirectoryIdentity.read(parent)
        if plan != nil, fm.fileExists(atPath: target.path) { throw PhotoError("目的地已有同名檔案，不會覆蓋： \(target.path)") }
        try FileSafety.ensureWriteCapacity(target, fileSize: sourceIdentity.size,
                                          copies: plan == nil ? 3 : 2, sourceMustBeWritable: plan == nil)
        let stage = SafeFileTransaction.temporaryPhoto(beside: target)
        var stagedSidecars: [(source: URL, stage: URL, target: URL, identity: FileIdentity)] = []
        defer {
            try? fm.removeItem(at: stage)
            for sidecar in stagedSidecars { try? fm.removeItem(at: sidecar.stage) }
        }
        try SafeFileTransaction.copyCandidate(item.url, to: stage)
        var writeWarnings = ""
        if !assignments.isEmpty {
            let attributes = try fm.attributesOfItem(atPath: stage.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            try fm.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: stage.path)
            let output = try tool.execute(["-charset", "filename=UTF8", "-P", "-overwrite_original_in_place"] +
                assignments.map { "-ExifIFD:\($0.0)=\($0.1)" } + [stage.path], timeout: 600,
                cancellation: cancellation)
            guard output.status == 0 else { throw PhotoError("Candidate write failed; original not changed. \(output.text)") }
            writeWarnings = output.stderr
        }
        let candidateSnapshot = try tool.snapshot(stage, cancellation: cancellation)
        notices += try MetadataVerifier.verify(before: originalSnapshot, after: candidateSnapshot,
                                               assignments: assignments, options: options)
        var after = candidateSnapshot.metadata
        notices += TimeValidation.issues(after)
        for read in sidecarReads { notices += read.issues(for: after) }
        after.compatibilityIssues = Array(Set(notices)).sorted()
        try FileSafety.preserveAndVerifyFileAttributes(from: item.url, to: stage)
        try SafeFileTransaction.syncFile(stage)
        if let plan, options.copySidecars {
            for source in sidecars {
                let output = target.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent)
                if try plan.hasCopied(sidecar: source, to: output) { continue }
                guard !fm.fileExists(atPath: output.path) else { throw PhotoError("Sidecar output already exists; photo was not published: \(output.path)") }
                let identity = try FileIdentity.read(source)
                try FileSafety.ensureWriteCapacity(output, fileSize: identity.size, copies: 1, sourceMustBeWritable: false)
                let temporary = output.deletingLastPathComponent().appendingPathComponent(".sidecar-\(UUID().uuidString)")
                // Register before copying so a failed partial copy is also cleaned.
                stagedSidecars.append((source, temporary, output, identity))
                try SafeFileTransaction.copyAndSync(source, to: temporary)
                try identity.verify(source)
            }
        } else if plan != nil && !sidecars.isEmpty {
            notices.append("Sidecars were not copied because copySidecars is disabled.")
        }
        try sourceIdentity.verify(item.url)
        try parentIdentity.verify(parent)
        try plan?.verify()
        if cancellation.isCancelled { throw CancellationError() }
        let backup: URL?
        if plan == nil {
            let oldest = URL(fileURLWithPath: item.url.path + "_original")
            if fm.fileExists(atPath: oldest.path) {
                try FileSafety.ensureRegular(oldest)
                try store.verifyCanonicalOriginalBackup(oldest, source: item.url)
                _ = try tool.inspect(oldest, cancellation: cancellation, strictOffsets: false)
                backup = URL(fileURLWithPath: item.url.path + ".before-write-\(UUID().uuidString).backup")
            } else { backup = oldest }
        } else { backup = nil }
        let sidecarCandidateIdentities = try Dictionary(uniqueKeysWithValues:
            stagedSidecars.map { ($0.stage.path, try FileIdentity.read($0.stage)) }
        )
        var manifest = TransactionManifest(version: 2, id: UUID(), source: item.url, target: target,
            candidate: stage, backup: backup, sourceIdentity: sourceIdentity,
            targetIdentityBefore: plan == nil ? sourceIdentity : nil,
            candidateIdentity: try FileIdentity.read(stage),
            sidecarCandidateIdentities: sidecarCandidateIdentities,
            originalDates: before.dateTags,
            oldOffsets: Dictionary(uniqueKeysWithValues: allFields.compactMap { tag, value in value.map { (tag, $0) } }),
            newOffsets: Dictionary(uniqueKeysWithValues: allFields.compactMap { tag, value in
                let newValue = assignments.first { $0.0 == tag }?.1 ?? value
                return newValue.map { (tag, $0) }
            }), sidecarTargets: stagedSidecars.map(\.target), publishedSidecars: [], phase: .prepared, detail: "metadata-only; no content hashes")
        item.transactionID = manifest.id; item.backupURL = backup
        try store.save(manifest)
        var photoPublished = false
        do {
            if let backup {
                let temp = backup.deletingLastPathComponent().appendingPathComponent(".photo-timezone-backup-\(UUID().uuidString).backup")
                defer { try? fm.removeItem(at: temp) }
                try SafeFileTransaction.copyAndSync(item.url, to: temp)
                try sourceIdentity.verify(item.url)
                try SafeFileTransaction.publishExclusive(temp, to: backup)
                if backup.standardizedFileURL.path == item.url.standardizedFileURL.path + "_original" {
                    manifest.canonicalBackupIdentity = try FileIdentity.read(backup)
                }
                manifest.phase = .backupDurable
                try store.save(manifest)
            }
            // No cancellation after this boundary: finish the durable transaction.
            try sourceIdentity.verify(item.url)
            try parentIdentity.verify(parent)
            try plan?.verify()
            try SidecarSupport.verifyUnchanged(sidecars, beside: item.url, index: sidecarIndex)
            for sidecar in stagedSidecars { try sidecar.identity.verify(sidecar.source) }
            for read in sidecarReads { try read.identity.verify(read.url) }
            do {
                if plan == nil { try SafeFileTransaction.replace(stage, at: target) }
                else { try SafeFileTransaction.publishExclusive(stage, to: target) }
                photoPublished = true
            } catch let error as PublicationError {
                photoPublished = true
                throw error
            }
            item.outputURL = target; item.outputMetadata = after
            item.metadata = plan == nil ? after : before
            for sidecar in stagedSidecars {
                try SafeFileTransaction.publishExclusive(sidecar.stage, to: sidecar.target)
                manifest.publishedSidecars.append(sidecar.target)
                try plan?.remember(sidecar: sidecar.source, sourceIdentity: sidecar.identity, output: sidecar.target)
            }
            manifest.phase = .committed
            manifest.detail = "Authorized EXIF offsets verified; all captured date fields unchanged; image bytes not hashed."
            try store.finish(manifest)
        } catch {
            if photoPublished {
                manifest.phase = .publicationUnconfirmed
                item.publicationUnconfirmed = true
                item.outputURL = target; item.outputMetadata = after
                item.metadata = plan == nil ? after : before
                manifest.detail = "Photo has been published. Review durability/sidecar completion before retry: \(error.localizedDescription)"
                try? store.save(manifest)
                throw PhotoError("Photo already published; NOT safe to retry automatically. \(target.path)\n\(manifest.detail)\nTransaction: \(manifest.id)")
            }
            manifest.phase = .aborted; manifest.detail = error.localizedDescription
            try? store.finish(manifest)
            throw error
        }
        item.status = .success
        item.detail = plan == nil
            ? "Offsets written and metadata verified; original dates unchanged. Backup: \(backup?.path ?? "")"
            : (assignments.isEmpty ? "原樣輸出：\(target.path)" : "Copy written and metadata verified: \(target.path). Source unchanged.")
        item.detail += "\nValidation: readable metadata only; no image or whole-file HASH."
        let warnings = [originalSnapshot.warnings, candidateSnapshot.warnings, writeWarnings] + notices
        let unique = Array(Set(warnings.filter { !$0.isEmpty })).sorted()
        if !unique.isEmpty { item.detail += "\n" + unique.joined(separator: "\n") }
    }

    private func writeGPS(
        item: inout PhotoItem, tool: ExifTool, location: GPSCoordinate, options: WriteOptions,
        plan: DestinationPlan?, store: TransactionStore, sidecarIndex: SidecarIndex, cancellation: CancellationToken
    ) throws {
        let fm = FileManager.default
        let sourceIdentity = try FileIdentity.read(item.url)
        if plan == nil, sourceIdentity.links > 1 {
            throw PhotoError("Original has hard links. Use copy mode to avoid breaking linked-file semantics.")
        }

        let originalSnapshot = try tool.snapshot(item.url, cancellation: cancellation)
        var before = originalSnapshot.metadata
        try sourceIdentity.verify(item.url)

        let sidecars = try SidecarSupport.find(beside: item.url, index: sidecarIndex)
        let sidecarReads = try sidecars.filter { $0.pathExtension.lowercased() == "xmp" }
            .map { try tool.readSidecar($0, cancellation: cancellation) }
        before.sidecarGPSDetected = sidecarReads.contains { $0.hasGPS }
        before.gpsSafetyUncertain = sidecarReads.contains { !$0.gpsCheckReliable }
        before.compatibilityIssues = Array(Set(
            before.compatibilityIssues + sidecarReads.flatMap { $0.issues(for: before) }
        )).sorted()
        item.metadata = before

        guard before.canSafelyAddGPS else {
            try sourceIdentity.verify(item.url)
            item.status = .skipped
            if before.gpsSafetyUncertain {
                item.detail = "無法可靠確認 XMP sidecar 是否含 GPS；為避免位置衝突，未寫入。"
            } else if before.sidecarGPSDetected {
                item.detail = "XMP sidecar 已含 GPS；為避免 EXIF/XMP 位置衝突，未寫入。"
            } else if before.embeddedXMPGPSDetected {
                item.detail = "照片內嵌 XMP 已含 GPS；為避免覆寫既有位置資料，未寫入。"
            } else {
                item.detail = before.hasCompleteGPSCoordinate
                    ? "照片已含 EXIF GPS；不覆寫既有位置資料。"
                    : "照片已有部分 GPS 中繼資料；為避免破壞或覆寫，未自動補寫。"
            }
            return
        }
        if cancellation.isCancelled { throw CancellationError() }

        let target = try plan?.output(for: item.url) ?? item.url
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        let parentIdentity = try DirectoryIdentity.read(parent)
        if plan != nil, fm.fileExists(atPath: target.path) {
            throw PhotoError("目的地已有同名檔案，不會覆蓋： \(target.path)")
        }
        try FileSafety.ensureWriteCapacity(target, fileSize: sourceIdentity.size,
                                          copies: plan == nil ? 3 : 2, sourceMustBeWritable: plan == nil)

        let stage = SafeFileTransaction.temporaryPhoto(beside: target)
        var stagedSidecars: [(source: URL, stage: URL, target: URL, identity: FileIdentity)] = []
        defer {
            try? fm.removeItem(at: stage)
            for sidecar in stagedSidecars { try? fm.removeItem(at: sidecar.stage) }
        }
        try SafeFileTransaction.copyCandidate(item.url, to: stage)

        let attributes = try fm.attributesOfItem(atPath: stage.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try fm.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: stage.path)

        var arguments = [
            "-charset", "filename=UTF8", "-P", "-overwrite_original_in_place",
            "-GPSVersionID=2.3.0.0",
            "-GPSLatitude#=\(location.latitudeArgument)",
            "-GPSLatitudeRef=\(location.latitudeRef)",
            "-GPSLongitude#=\(location.longitudeArgument)",
            "-GPSLongitudeRef=\(location.longitudeRef)"
        ]
        if let altitude = location.altitudeArgument, let altitudeRef = location.altitudeRef {
            arguments += ["-GPSAltitude#=\(altitude)", "-GPSAltitudeRef#=\(altitudeRef)"]
        }
        arguments.append(stage.path)
        let output = try tool.execute(arguments, timeout: 600, cancellation: cancellation)
        guard output.status == 0 else {
            throw PhotoError("GPS 候選檔寫入失敗；原檔未更動。 \(output.text)")
        }

        let candidateSnapshot = try tool.snapshot(stage, cancellation: cancellation)
        var notices = try MetadataVerifier.verifyGPSAddition(
            before: originalSnapshot, after: candidateSnapshot, location: location, options: options
        )
        var after = candidateSnapshot.metadata
        after.sidecarGPSDetected = before.sidecarGPSDetected
        after.gpsSafetyUncertain = before.gpsSafetyUncertain
        notices += TimeValidation.issues(after)
        for read in sidecarReads { notices += read.issues(for: after) }
        if !sidecars.isEmpty {
            notices.append("Sidecars detected: \(sidecars.map(\.lastPathComponent).joined(separator: ", ")). Sidecars were not rewritten.")
        }
        after.compatibilityIssues = Array(Set(notices)).sorted()

        try FileSafety.preserveAndVerifyFileAttributes(from: item.url, to: stage)
        try SafeFileTransaction.syncFile(stage)

        if let plan, options.copySidecars {
            for source in sidecars {
                let sidecarTarget = target.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent)
                if try plan.hasCopied(sidecar: source, to: sidecarTarget) { continue }
                guard !fm.fileExists(atPath: sidecarTarget.path) else {
                    throw PhotoError("Sidecar output already exists; photo was not published: \(sidecarTarget.path)")
                }
                let identity = try FileIdentity.read(source)
                try FileSafety.ensureWriteCapacity(sidecarTarget, fileSize: identity.size, copies: 1, sourceMustBeWritable: false)
                let temporary = sidecarTarget.deletingLastPathComponent()
                    .appendingPathComponent(".sidecar-\(UUID().uuidString)")
                stagedSidecars.append((source, temporary, sidecarTarget, identity))
                try SafeFileTransaction.copyAndSync(source, to: temporary)
                try identity.verify(source)
            }
        }

        try sourceIdentity.verify(item.url)
        try parentIdentity.verify(parent)
        try plan?.verify()
        if cancellation.isCancelled { throw CancellationError() }

        let backup: URL?
        if plan == nil {
            let oldest = URL(fileURLWithPath: item.url.path + "_original")
            if fm.fileExists(atPath: oldest.path) {
                try FileSafety.ensureRegular(oldest)
                try store.verifyCanonicalOriginalBackup(oldest, source: item.url)
                _ = try tool.inspect(oldest, cancellation: cancellation, strictOffsets: false)
                backup = URL(fileURLWithPath: item.url.path + ".before-write-\(UUID().uuidString).backup")
            } else {
                backup = oldest
            }
        } else {
            backup = nil
        }

        let allOffsets: [(String, String?)] = [
            ("OffsetTimeOriginal", before.offsetOriginal),
            ("OffsetTimeDigitized", before.offsetDigitized),
            ("OffsetTime", before.offsetTime)
        ]
        let preservedOffsets = Dictionary(uniqueKeysWithValues: allOffsets.compactMap { tag, value in
            value.map { (tag, $0) }
        })

        let sidecarCandidateIdentities = try Dictionary(uniqueKeysWithValues:
            stagedSidecars.map { ($0.stage.path, try FileIdentity.read($0.stage)) }
        )
        var manifest = TransactionManifest(
            version: 2, id: UUID(), source: item.url, target: target,
            candidate: stage, backup: backup, sourceIdentity: sourceIdentity,
            targetIdentityBefore: plan == nil ? sourceIdentity : nil,
            candidateIdentity: try FileIdentity.read(stage),
            sidecarCandidateIdentities: sidecarCandidateIdentities,
            originalDates: before.dateTags,
            oldOffsets: preservedOffsets, newOffsets: preservedOffsets,
            sidecarTargets: stagedSidecars.map(\.target), publishedSidecars: [],
            phase: .prepared,
            detail: "GPS-only metadata addition \(location.display); dates and EXIF offsets unchanged; no content hashes"
        )
        item.transactionID = manifest.id
        item.backupURL = backup
        try store.save(manifest)

        var photoPublished = false
        do {
            if let backup {
                let temp = backup.deletingLastPathComponent()
                    .appendingPathComponent(".photo-timezone-backup-\(UUID().uuidString).backup")
                defer { try? fm.removeItem(at: temp) }
                try SafeFileTransaction.copyAndSync(item.url, to: temp)
                try sourceIdentity.verify(item.url)
                try SafeFileTransaction.publishExclusive(temp, to: backup)
                if backup.standardizedFileURL.path == item.url.standardizedFileURL.path + "_original" {
                    manifest.canonicalBackupIdentity = try FileIdentity.read(backup)
                }
                manifest.phase = .backupDurable
                try store.save(manifest)
            }

            try sourceIdentity.verify(item.url)
            try parentIdentity.verify(parent)
            try plan?.verify()
            try SidecarSupport.verifyUnchanged(sidecars, beside: item.url, index: sidecarIndex)
            for sidecar in stagedSidecars { try sidecar.identity.verify(sidecar.source) }
            for read in sidecarReads { try read.identity.verify(read.url) }

            do {
                if plan == nil { try SafeFileTransaction.replace(stage, at: target) }
                else { try SafeFileTransaction.publishExclusive(stage, to: target) }
                photoPublished = true
            } catch let error as PublicationError {
                photoPublished = true
                throw error
            }

            item.outputURL = target
            item.outputMetadata = after
            item.metadata = plan == nil ? after : before
            for sidecar in stagedSidecars {
                try SafeFileTransaction.publishExclusive(sidecar.stage, to: sidecar.target)
                manifest.publishedSidecars.append(sidecar.target)
                try plan?.remember(sidecar: sidecar.source, sourceIdentity: sidecar.identity, output: sidecar.target)
            }
            manifest.phase = .committed
            manifest.detail = "GPS-only metadata addition verified; dates and EXIF offsets unchanged; image bytes not hashed."
            try store.finish(manifest)
        } catch {
            if photoPublished {
                manifest.phase = .publicationUnconfirmed
                item.publicationUnconfirmed = true
                item.outputURL = target
                item.outputMetadata = after
                item.metadata = plan == nil ? after : before
                manifest.detail = "GPS photo has been published. Review durability/sidecar completion before retry: \(error.localizedDescription)"
                try? store.save(manifest)
                throw PhotoError("Photo already published; NOT safe to retry automatically. \(target.path)\n\(manifest.detail)\nTransaction: \(manifest.id)")
            }
            manifest.phase = .aborted
            manifest.detail = error.localizedDescription
            try? store.finish(manifest)
            throw error
        }

        item.status = .success
        item.detail = plan == nil
            ? "GPS \(location.display) 已新增並驗證；原日期、時間與時區欄位未變。備份：\(backup?.path ?? "")"
            : "GPS \(location.display) 已寫入副本：\(target.path)。來源照片未修改。"
        item.detail += "\nValidation: GPS-only readable metadata whitelist; no image or whole-file HASH."
        let warnings = [originalSnapshot.warnings, candidateSnapshot.warnings, output.stderr] + notices
        let unique = Array(Set(warnings.filter { !$0.isEmpty })).sorted()
        if !unique.isEmpty { item.detail += "\n" + unique.joined(separator: "\n") }
    }

    private func restore(item: inout PhotoItem, tool: ExifTool, store: TransactionStore,
                         cancellation: CancellationToken) throws {
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: item.url.path + "_original")
        guard fm.fileExists(atPath: backup.path) else {
            item.status = .skipped; item.detail = "No _original backup; nothing changed."; return
        }
        try store.verifyCanonicalOriginalBackup(backup, source: item.url)
        let backupIdentity = try FileIdentity.read(backup)
        let before = try tool.snapshot(backup, cancellation: cancellation, strictOffsets: false)
        let currentIdentity = fm.fileExists(atPath: item.url.path) ? try FileIdentity.read(item.url) : nil
        if let currentIdentity, currentIdentity.links > 1 { throw PhotoError("Restore would break hard links; use an independent copy.") }
        try FileSafety.ensureWriteCapacity(item.url, fileSize: max(backupIdentity.size, currentIdentity?.size ?? 0),
                                          copies: 3, sourceMustBeWritable: false)
        let stage = SafeFileTransaction.temporaryPhoto(beside: item.url)
        defer { try? fm.removeItem(at: stage) }
        try SafeFileTransaction.copyAndSync(backup, to: stage)
        guard try SafeFileTransaction.contentsAreIdentical(backup, stage) else {
            throw PhotoError("Restore candidate bytes differ from the backup; no original was changed.")
        }
        let candidate = try tool.snapshot(stage, cancellation: cancellation, strictOffsets: false)
        try backupIdentity.verify(backup)
        try currentIdentity?.verify(item.url)
        if cancellation.isCancelled { throw CancellationError() }
        let currentCopy = currentIdentity.map { _ in URL(fileURLWithPath: item.url.path + ".before-restore-\(UUID().uuidString).backup") }
        let parent = item.url.deletingLastPathComponent().resolvingSymlinksInPath()
        let parentIdentity = try DirectoryIdentity.read(parent)
        var manifest = TransactionManifest(version: 2, id: UUID(), source: backup, target: item.url,
            candidate: stage, backup: currentCopy ?? backup, sourceIdentity: backupIdentity,
            targetIdentityBefore: currentIdentity,
            candidateIdentity: try FileIdentity.read(stage), originalDates: before.metadata.dateTags,
            oldOffsets: [:], newOffsets: [:], sidecarTargets: [], publishedSidecars: [], phase: .prepared,
            detail: "Whole-file restore, not an offset-only undo. Candidate verified byte-for-byte against the canonical backup.")
        item.transactionID = manifest.id; item.backupURL = currentCopy ?? backup
        try store.save(manifest)
        var published = false
        do {
            if let currentCopy {
                let temp = currentCopy.deletingLastPathComponent().appendingPathComponent(".before-restore-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: temp) }
                try SafeFileTransaction.copyAndSync(item.url, to: temp)
                try currentIdentity?.verify(item.url)
                try SafeFileTransaction.publishExclusive(temp, to: currentCopy)
            }
            try backupIdentity.verify(backup); try currentIdentity?.verify(item.url)
            try parentIdentity.verify(parent)
            do {
                if currentIdentity == nil { try SafeFileTransaction.publishExclusive(stage, to: item.url) }
                else { try SafeFileTransaction.replace(stage, at: item.url) }
                published = true
            } catch let error as PublicationError { published = true; throw error }
            item.metadata = candidate.metadata; item.outputURL = item.url
            manifest.phase = .committed
            try store.finish(manifest)
        } catch {
            if published {
                item.publicationUnconfirmed = true; item.outputURL = item.url
                item.metadata = candidate.metadata
                manifest.phase = .publicationUnconfirmed
                manifest.detail = "Restore was published; durability confirmation incomplete. \(error.localizedDescription)"
                try? store.save(manifest)
                throw PhotoError(manifest.detail + " Do not retry automatically; backups retained.")
            }
            manifest.phase = .aborted; manifest.detail = error.localizedDescription
            try? store.finish(manifest)
            throw error
        }
        item.status = .success
        item.detail = "Whole-file restore completed; backup and previous version retained. Restore candidate verified byte-for-byte against the canonical backup."
    }

}

private final class Journal {
    let url: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private var linesSinceSync = 0
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
    func finish(_ message: String) throws { try line(["summary": message, "finishedAt": ISO8601DateFormatter().string(from: Date())]); try handle.synchronize() }
    private func line<T: Encodable>(_ value: T) throws {
        try handle.write(contentsOf: encoder.encode(value) + Data([0x0a]))
        linesSinceSync += 1
        if linesSinceSync >= 48 { try handle.synchronize(); linesSinceSync = 0 }
    }
}

final class JobLock {
    private var descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PhotoError("無法建立工作鎖。") }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            descriptor = -1
            throw PhotoError("另一個相片時區修改器正在處理；請等候它完成。")
        }
    }
    func release() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
    deinit { release() }
}
