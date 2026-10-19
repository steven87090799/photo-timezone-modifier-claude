import Foundation

/// Restore the canonical photo and its original sidecars as one journalled
/// operation. Every replacement has a durable copy of the current version.
enum BundleRestore {
    struct Candidate {
        let backup: URL
        let backupIdentity: FileIdentity
        let target: URL
        let currentIdentity: FileIdentity?
        let stage: URL
        let stageIdentity: FileIdentity
        let previous: URL?
        var previousIdentity: FileIdentity?
    }

    static func restore(item: inout PhotoItem, tool: ExifTool, store: TransactionStore,
                        cancellation: CancellationToken) throws {
        let fm = FileManager.default
        let photo = item.url
        let backup = URL(fileURLWithPath: photo.path + "_original")
        guard fm.fileExists(atPath: backup.path) else {
            item.status = .skipped
            item.detail = "No _original backup; nothing changed."
            return
        }
        try store.verifyCanonicalOriginalBackup(backup, source: photo)
        let photoBackupIdentity = try FileIdentity.read(backup)
        let original = try tool.snapshot(backup, cancellation: cancellation, strictOffsets: false)
        let sidecarBackups = try store.canonicalSidecarBackups(backup, source: photo)
        let currentSidecars = try SidecarSupport.find(beside: photo)
        let originalPaths = Set(sidecarBackups.keys)
        guard Set(currentSidecars.map(\.path)).isSubset(of: originalPaths) else {
            throw PhotoError("目前有不屬於原始備份組的伴隨檔；無法保證照片與 XMP 完整還原。請保留備份並人工檢查，尚未修改照片。")
        }
        let parent = photo.deletingLastPathComponent().resolvingSymlinksInPath()
        let parentIdentity = try DirectoryIdentity.read(parent)
        var candidates: [Candidate] = []
        var stages: [URL] = []
        defer { for stage in stages { try? fm.removeItem(at: stage) } }
        let sources = sidecarBackups.keys.sorted().map { path in
            (sidecarBackups[path]!.url, URL(fileURLWithPath: path), sidecarBackups[path]!.identity)
        } + [(backup, photo, photoBackupIdentity)]
        for (source, target, pinned) in sources {
            try pinned.verify(source)
            let current = fm.fileExists(atPath: target.path) ? try FileIdentity.read(target) : nil
            if let current, current.links > 1 {
                throw PhotoError("還原會破壞照片或伴隨檔的硬連結；請先建立獨立副本。")
            }
            try FileSafety.ensureWriteCapacity(target, fileSize: max(pinned.size, current?.size ?? 0),
                copies: 3, sourceMustBeWritable: false)
            let stage = target == photo ? SafeFileTransaction.temporaryPhoto(beside: target) :
                target.deletingLastPathComponent().appendingPathComponent(".sidecar-\(UUID().uuidString).\(target.pathExtension)")
            stages.append(stage)
            try SafeFileTransaction.copyAndSync(source, to: stage)
            guard try SafeFileTransaction.contentsAreIdentical(source, stage) else {
                throw PhotoError("還原候選檔與原始備份內容不同；所有來源均未修改。")
            }
            candidates.append(Candidate(backup: source, backupIdentity: pinned, target: target,
                currentIdentity: current, stage: stage, stageIdentity: try FileIdentity.read(stage),
                previous: current.map { _ in URL(fileURLWithPath: target.path + ".before-restore-\(UUID().uuidString).backup") }))
        }
        // Also decode the staged photo before the publication boundary.
        let restored = try tool.snapshot(candidates.last!.stage, cancellation: cancellation, strictOffsets: false)
        try verifySourcesAndTargets(candidates)
        try SidecarSupport.verifyUnchanged(currentSidecars, beside: photo)
        try parentIdentity.verify(parent)
        if cancellation.isCancelled { throw CancellationError() }
        let photoCandidate = candidates.last!
        var manifest = TransactionManifest(version: 4, id: UUID(), source: backup, target: photo,
            candidate: photoCandidate.stage, backup: photoCandidate.previous ?? backup,
            sourceIdentity: photoBackupIdentity, targetIdentityBefore: photoCandidate.currentIdentity,
            candidateIdentity: photoCandidate.stageIdentity,
            sidecarCandidateIdentities: Dictionary(uniqueKeysWithValues: candidates.dropLast().map { ($0.stage.path, $0.stageIdentity) }),
            originalDates: original.metadata.dateTags, oldOffsets: [:], newOffsets: [:],
            sidecarTargets: candidates.dropLast().map(\.target), publishedSidecars: [], phase: .prepared,
            detail: "Canonical photo and sidecar restore; candidates compared byte-for-byte with pinned backups.")
        manifest.sidecarBackups = Dictionary(uniqueKeysWithValues: candidates.dropLast().compactMap { candidate in
            candidate.previous.map { (candidate.target.path, $0) }
        })
        manifest.sidecarBackupIdentities = [:]
        item.transactionID = manifest.id
        item.backupURL = photoCandidate.previous ?? backup
        try store.save(manifest)
        var published: [Candidate] = []
        do {
            for index in candidates.indices {
                guard let previous = candidates[index].previous,
                      let expected = candidates[index].currentIdentity else { continue }
                let temp = previous.deletingLastPathComponent().appendingPathComponent(".before-restore-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: temp) }
                try SafeFileTransaction.copyAndSync(candidates[index].target, to: temp)
                guard try SafeFileTransaction.contentsAreIdentical(candidates[index].target, temp) else {
                    throw PhotoError("還原前的保留副本驗證失敗；未發佈還原結果。")
                }
                try expected.verify(candidates[index].target)
                try SafeFileTransaction.publishExclusive(temp, to: previous)
                try SafeFileTransaction.fullSyncFile(previous)
                candidates[index].previousIdentity = try FileIdentity.read(previous)
                if candidates[index].target != photo {
                    manifest.sidecarBackupIdentities?[candidates[index].target.path] = candidates[index].previousIdentity
                }
            }
            manifest.phase = .backupDurable
            try store.save(manifest)
            try verifySourcesAndTargets(candidates)
            try SidecarSupport.verifyUnchanged(currentSidecars, beside: photo)
            try parentIdentity.verify(parent)
            // Finish the bundle even if cancellation arrives after this point.
            for candidate in candidates {
                do {
                    if candidate.currentIdentity == nil {
                        try SafeFileTransaction.publishExclusive(candidate.stage, to: candidate.target)
                    } else {
                        try SafeFileTransaction.replace(candidate.stage, at: candidate.target)
                    }
                    published.append(candidate)
                } catch let error as PublicationError {
                    published.append(candidate)
                    throw error
                }
                if candidate.target != photo {
                    manifest.publishedSidecars.append(candidate.target)
                    try store.save(manifest)
                }
            }
            for candidate in candidates {
                try verifyPublished(candidate.stageIdentity, at: candidate.target)
                try candidate.backupIdentity.verify(candidate.backup)
                guard try SafeFileTransaction.contentsAreIdentical(candidate.backup, candidate.target) else {
                    throw PhotoError("發佈後的照片或伴隨檔與原始備份不同；還原未完成。")
                }
            }
            manifest.phase = .committed
            try store.finish(manifest)
        } catch {
            if !published.isEmpty {
                let rollback = rollbackPublished(published)
                manifest.phase = .publicationUnconfirmed
                manifest.detail = "Bundle restore publication failed: \(error.localizedDescription). \(rollback)"
                item.publicationUnconfirmed = true
                try? store.save(manifest)
                throw PhotoError(manifest.detail + " 請保留所有備份，檢查交易紀錄後再重試。")
            }
            manifest.phase = .aborted
            manifest.detail = error.localizedDescription
            try? store.finish(manifest)
            throw error
        }
        item.metadata = restored.metadata
        item.outputURL = photo
        item.status = .success
        item.detail = "Whole-file restore completed for photo and \(sidecarBackups.count) sidecar(s); original backups and previous versions retained. All restored files verified byte-for-byte."
    }

    private static func verifySourcesAndTargets(_ candidates: [Candidate]) throws {
        for candidate in candidates {
            try candidate.backupIdentity.verify(candidate.backup)
            try candidate.stageIdentity.verify(candidate.stage)
            if let current = candidate.currentIdentity { try current.verify(candidate.target) }
            else if FileManager.default.fileExists(atPath: candidate.target.path) {
                throw PhotoError("還原目的地在處理期間已出現其他檔案；未覆蓋。")
            }
        }
    }

    static func rollbackPublished(_ published: [Candidate]) -> String {
        var errors: [String] = []
        for candidate in published.reversed() {
            do {
                try verifyPublished(candidate.stageIdentity, at: candidate.target)
                if let previous = candidate.previous, let pinned = candidate.previousIdentity {
                    try pinned.verify(previous)
                    let stage = SafeFileTransaction.temporaryPhoto(beside: candidate.target)
                    defer { try? FileManager.default.removeItem(at: stage) }
                    try SafeFileTransaction.copyAndSync(previous, to: stage)
                    guard try SafeFileTransaction.contentsAreIdentical(previous, stage) else {
                        throw PhotoError("Rollback candidate differs from its backup.")
                    }
                    try verifyPublished(candidate.stageIdentity, at: candidate.target)
                    try SafeFileTransaction.replace(stage, at: candidate.target)
                } else if candidate.currentIdentity == nil {
                    try FileManager.default.removeItem(at: candidate.target)
                    try SafeFileTransaction.syncDirectory(candidate.target.deletingLastPathComponent())
                } else {
                    throw PhotoError("Missing pinned previous-version backup.")
                }
            } catch { errors.append("\(candidate.target.lastPathComponent): \(error.localizedDescription)") }
        }
        return errors.isEmpty ? "Published files returned to their previous state; backups retained." :
            "Automatic rollback incomplete: \(errors.joined(separator: "; "))"
    }

    private static func verifyPublished(_ expected: FileIdentity, at url: URL) throws {
        let actual = try FileIdentity.read(url)
        guard expected.device == actual.device, expected.inode == actual.inode,
              expected.size == actual.size,
              expected.modifiedSeconds == actual.modifiedSeconds,
              expected.modifiedNanoseconds == actual.modifiedNanoseconds,
              expected.mode & 0o7777 == actual.mode & 0o7777 else {
            throw PhotoError("已發佈檔案的身分改變；未自動覆蓋 \(url.path)。")
        }
    }
}
