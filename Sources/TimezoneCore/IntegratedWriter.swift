import Foundation

/// Plans one photo and every associated XMP sidecar before any visible file is
/// changed. A failed candidate never reaches the source. All published files
/// have durable backups; an interrupted multi-file publication remains in the
/// transaction journal and is never reported as a successful photo.
enum IntegratedWriter {
    private struct SidecarCandidate {
        let source: URL
        let target: URL
        let stage: URL
        let identity: FileIdentity
        let before: ExifTool.SidecarSnapshot?
        let allowedChanges: Set<String>
        var backup: URL?
    }

    static func write(item: inout PhotoItem, tool: ExifTool, offset: UTCOffset, mode: WriteMode,
                      options: WriteOptions, plan: DestinationPlan?, store: TransactionStore,
                      sidecarIndex: SidecarIndex, cancellation: CancellationToken) throws {
        let fm = FileManager.default
        let source = item.url
        let originalIdentity = try FileIdentity.read(source)
        if plan == nil && originalIdentity.links > 1 {
            throw PhotoError("原檔有硬連結；請使用副本模式。")
        }
        let original = try tool.snapshot(source, cancellation: cancellation)
        var before = original.metadata
        let sidecars = try SidecarSupport.find(beside: source, index: sidecarIndex)
        let xmpReads = try sidecars.filter { $0.pathExtension.lowercased() == "xmp" }
            .map { try tool.readSidecar($0, cancellation: cancellation) }
        before.sidecarGPSDetected = xmpReads.contains { $0.hasGPS }
        before.gpsSafetyUncertain = xmpReads.contains { !$0.gpsCheckReliable }
        item.metadata = before

        let changeTimezone = options.timezonePaths?.contains(source.path) ?? true
        if changeTimezone { try TimeValidation.validateForWrite(before, mode: mode) }
        let oldOffsets: [(String, String?)] = [
            ("OffsetTimeOriginal", before.offsetOriginal),
            ("OffsetTimeDigitized", before.offsetDigitized),
            ("OffsetTime", before.offsetTime)
        ]
        let exifAssignments = changeTimezone ? oldOffsets.compactMap { tag, old -> (String, String)? in
            (mode == .replaceAll || old == nil) && old != offset.value ? (tag, offset.value) : nil
        } : []
        func resultingOffset(_ name: String) -> String {
            exifAssignments.first { $0.0 == name }?.1 ?? oldOffsets.first { $0.0 == name }?.1 ?? offset.value
        }

        var gpsAction: GPSWriteRequest?
        var gpsResult = "未啟用"
        if let gps = options.gps {
            if before.gpsSafetyUncertain {
                gpsResult = "失敗：XMP sidecar 過大或無法可靠檢查"
                throw PhotoError("時區：未寫入；GPS：\(gpsResult)。\(xmpReads.filter { !$0.gpsCheckReliable }.map(\.warning).joined(separator: " "))")
            }
            if before.hasAnyGPS && !gps.overwrite {
                gpsResult = before.hasCompleteGPSCoordinate ? "保留既有 GPS" :
                    "保留已有或部分 GPS（EXIF／內嵌 XMP／sidecar）"
            } else {
                gpsAction = gps
                gpsResult = gps.overwrite ? "覆蓋 GPS" : "補入 GPS"
            }
        }
        if gpsAction != nil {
            let supportedEXIF: Set<String> = ["GPSLatitude", "GPSLatitudeRef",
                "GPSLongitude", "GPSLongitudeRef", "GPSAltitude", "GPSAltitudeRef"]
            for key in original.embeddedTags.keys where key.hasPrefix("GPS:") {
                let tag = tagName(key)
                guard supportedEXIF.contains(tag) ||
                    (!tag.contains("Latitude") && !tag.contains("Longitude") &&
                     !tag.contains("Altitude") && tag != "GPSAreaInformation") else {
                    throw PhotoError("時區：未寫入；GPS：失敗。EXIF 含無法安全同步的 \(key)。")
                }
            }
        }
        if xmpReads.contains(where: { !$0.gpsCheckReliable }) && changeTimezone {
            throw PhotoError("時區：失敗；XMP sidecar 無法可靠讀取。GPS：\(gpsResult)。")
        }
        if !sidecars.isEmpty && !options.copySidecars && plan != nil {
            throw PhotoError("時區：未寫入；GPS：未寫入。副本必須同時輸出既有伴隨檔。")
        }

        let photoXMP = original.embeddedTags.filter { $0.key.hasPrefix("XMP") }
        let photoXMPAssignments = try xmpAssignments(tags: photoXMP, mode: mode,
            timezone: changeTimezone, resultingOffset: resultingOffset, gps: gpsAction)
        let photoGPSAssignments = gpsAction.map { gpsAssignments($0.coordinate, before: before) } ?? []
        var sidecarPlans: [(read: ExifTool.SidecarSnapshot, changes: [(String, String)])] = []
        for read in xmpReads {
            let changes = try xmpAssignments(tags: read.tags, mode: mode,
                timezone: changeTimezone, resultingOffset: resultingOffset, gps: gpsAction,
                existingXMPDocument: true)
            sidecarPlans.append((read, changes))
        }
        let photoChanges = exifAssignments.map { ("ExifIFD:\($0.0)", $0.1) }
            + photoXMPAssignments + photoGPSAssignments
        let anySidecarChange = sidecarPlans.contains { !$0.changes.isEmpty }
        let timezoneResult = changeTimezone
            ? (exifAssignments.isEmpty && photoXMPAssignments.allSatisfy { !dateFields.contains(tagName($0.0)) }
                && !sidecarPlans.contains(where: { $0.changes.contains(where: { dateFields.contains(tagName($0.0)) }) })
                ? "原有時區已齊，無需修改" : "已同步 EXIF／既有 XMP 時區")
            : "未包含於時區處理範圍"
        if photoChanges.isEmpty && !anySidecarChange && plan == nil {
            try originalIdentity.verify(source)
            for read in xmpReads { try read.identity.verify(read.url) }
            item.status = .skipped
            item.detail = "時區：\(timezoneResult)。GPS：\(gpsResult)。"
            return
        }
        if cancellation.isCancelled { throw CancellationError() }
        let target = try plan?.output(for: source) ?? source
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        let parentIdentity = try DirectoryIdentity.read(parent)
        if plan != nil && fm.fileExists(atPath: target.path) {
            throw PhotoError("目的地已有同名照片：\(target.path)")
        }
        try FileSafety.ensureWriteCapacity(target, fileSize: originalIdentity.size,
            copies: plan == nil ? 3 : 2, sourceMustBeWritable: plan == nil)
        let stage = SafeFileTransaction.temporaryPhoto(beside: target)
        var candidates: [SidecarCandidate] = []
        defer {
            try? fm.removeItem(at: stage)
            for candidate in candidates { try? fm.removeItem(at: candidate.stage) }
        }
        try SafeFileTransaction.copyCandidate(source, to: stage)
        if !photoChanges.isEmpty {
            try mutate(stage, assignments: photoChanges, tool: tool, cancellation: cancellation,
                priorToolkit: photoXMP["XMP-x:XMPToolkit"].flatMap(jsonString))
        }
        let afterSnapshot = try tool.snapshot(stage, cancellation: cancellation)
        try MetadataVerifier.verifyIntegrated(before: original, after: afterSnapshot,
            assignments: photoChanges, gps: gpsAction?.coordinate, options: options)
        try FileSafety.preserveAndVerifyFileAttributes(from: source, to: stage)
        try SafeFileTransaction.syncFile(stage)

        for sidecar in sidecars {
            let output = target.deletingLastPathComponent().appendingPathComponent(sidecar.lastPathComponent)
            let read = sidecarPlans.first { $0.read.url.path == sidecar.path }
            if plan != nil && !options.copySidecars { continue }
            if let plan, try plan.hasCopied(sidecar: sidecar, to: output) {
                throw PhotoError("多張照片共用同一個 XMP sidecar；無法保證同步：\(sidecar.lastPathComponent)")
            }
            if plan != nil && fm.fileExists(atPath: output.path) {
                throw PhotoError("目的地已有同名 sidecar：\(output.path)")
            }
            let identity: FileIdentity
            if let read { identity = read.read.identity }
            else { identity = try FileIdentity.read(sidecar) }
            try FileSafety.ensureWriteCapacity(output, fileSize: identity.size,
                copies: plan == nil ? 3 : 2, sourceMustBeWritable: plan == nil)
            let temporary = output.deletingLastPathComponent()
                .appendingPathComponent(".sidecar-\(UUID().uuidString).\(sidecar.pathExtension)")
            // Register first so a failed copy is cleaned up as well.
            candidates.append(SidecarCandidate(source: sidecar, target: output, stage: temporary,
                identity: identity, before: read?.read,
                allowedChanges: Set(read?.changes.map(\.0) ?? []), backup: nil))
            try SafeFileTransaction.copyCandidate(sidecar, to: temporary)
            if let read, !read.changes.isEmpty {
                try mutate(temporary, assignments: read.changes, tool: tool, cancellation: cancellation,
                    priorToolkit: read.read.tags["XMP-x:XMPToolkit"].flatMap(jsonString))
                let afterRead = try tool.readSidecar(temporary, cancellation: cancellation)
                try verifySidecar(before: read.read, after: afterRead,
                    assignments: read.changes, gps: gpsAction?.coordinate)
            } else if !(try SafeFileTransaction.contentsAreIdentical(sidecar, temporary)) {
                throw PhotoError("伴隨檔副本內容不符：\(sidecar.lastPathComponent)")
            }
            try FileSafety.preserveAndVerifyFileAttributes(from: sidecar, to: temporary)
            try SafeFileTransaction.syncFile(temporary)
        }
        try originalIdentity.verify(source)
        try SidecarSupport.verifyUnchanged(sidecars, beside: source, index: sidecarIndex)
        for candidate in candidates { try candidate.identity.verify(candidate.source) }
        try parentIdentity.verify(parent)
        try plan?.verify()
        if cancellation.isCancelled { throw CancellationError() }

        let photoBackup: URL?
        if plan == nil {
            let canonical = URL(fileURLWithPath: source.path + "_original")
            if fm.fileExists(atPath: canonical.path) {
                try FileSafety.ensureRegular(canonical)
                try store.verifyCanonicalOriginalBackup(canonical, source: source)
                photoBackup = URL(fileURLWithPath: source.path + ".before-write-\(UUID().uuidString).backup")
            } else { photoBackup = canonical }
            for index in candidates.indices {
                candidates[index].backup = URL(fileURLWithPath: candidates[index].source.path +
                    ".before-write-\(UUID().uuidString).backup")
            }
        } else { photoBackup = nil }

        var manifest = TransactionManifest(version: 3, id: UUID(), source: source, target: target,
            candidate: stage, backup: photoBackup, sourceIdentity: originalIdentity,
            targetIdentityBefore: plan == nil ? originalIdentity : nil,
            candidateIdentity: try FileIdentity.read(stage),
            sidecarCandidateIdentities: try Dictionary(uniqueKeysWithValues:
                candidates.map { ($0.stage.path, try FileIdentity.read($0.stage)) }),
            originalDates: before.dateTags,
            oldOffsets: Dictionary(uniqueKeysWithValues: oldOffsets.compactMap { name, value in value.map { (name, $0) } }),
            newOffsets: Dictionary(uniqueKeysWithValues: oldOffsets.compactMap { name, value in
                (changeTimezone ? resultingOffset(name) : value).map { (name, $0) }
            }), sidecarTargets: candidates.map(\.target), publishedSidecars: [],
            phase: .prepared, detail: "Photo and sidecar candidates verified before publication")
        manifest.sidecarBackups = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            candidate.backup.map { (candidate.source.path, $0) }
        })
        item.transactionID = manifest.id
        item.backupURL = photoBackup
        try store.save(manifest)
        var published: [URL] = []
        do {
            if let photoBackup {
                try durableBackup(source, to: photoBackup, expected: originalIdentity)
                if photoBackup.path == source.path + "_original" {
                    manifest.canonicalBackupIdentity = try FileIdentity.read(photoBackup)
                }
                for candidate in candidates {
                    if let backup = candidate.backup {
                        try durableBackup(candidate.source, to: backup, expected: candidate.identity)
                    }
                }
                manifest.phase = .backupDurable
                try store.save(manifest)
            }
            try originalIdentity.verify(source)
            try parentIdentity.verify(parent)
            try plan?.verify()
            try SidecarSupport.verifyUnchanged(sidecars, beside: source, index: sidecarIndex)
            for candidate in candidates { try candidate.identity.verify(candidate.source) }
            for candidate in candidates {
                // Publish sidecars first so the photo is the last visible change.
                do {
                    if plan == nil { try SafeFileTransaction.replace(candidate.stage, at: candidate.target) }
                    else { try SafeFileTransaction.publishExclusive(candidate.stage, to: candidate.target) }
                    published.append(candidate.target)
                } catch let error as PublicationError {
                    published.append(candidate.target)
                    throw error
                }
                manifest.publishedSidecars.append(candidate.target)
                try store.save(manifest)
            }
            do {
                if plan == nil { try SafeFileTransaction.replace(stage, at: target) }
                else { try SafeFileTransaction.publishExclusive(stage, to: target) }
                published.append(target)
            } catch let error as PublicationError {
                published.append(target)
                throw error
            }
            try verifyPublished(manifest.candidateIdentity!, at: target)
            let visiblePhoto = try tool.snapshot(target, cancellation: nil)
            try MetadataVerifier.verifyAssignedValues(photoChanges, in: visiblePhoto.embeddedTags)
            if let gps = gpsAction?.coordinate {
                try verifyPhotoGPS(visiblePhoto.metadata, coordinate: gps)
                try MetadataVerifier.verifyEXIFCoordinate(tags: visiblePhoto.embeddedTags,
                    coordinate: gps)
                if photoXMPAssignments.contains(where: { $0.0 == "XMP-exif:GPSLatitude" }) {
                    try MetadataVerifier.verifyXMPCoordinate(tags: visiblePhoto.embeddedTags,
                        coordinate: gps)
                }
            }
            for candidate in candidates where candidate.before != nil && !candidate.allowedChanges.isEmpty {
                let read = try tool.readSidecar(candidate.target)
                try verifySidecar(before: candidate.before!, after: read,
                    assignments: sidecarPlans.first { $0.read.url.path == candidate.source.path }?.changes ?? [],
                    gps: gpsAction?.coordinate)
            }
            item.outputURL = target
            item.outputMetadata = visiblePhoto.metadata
            item.metadata = plan == nil ? visiblePhoto.metadata : before
            for candidate in candidates {
                try plan?.remember(sidecar: candidate.source, sourceIdentity: candidate.identity, output: candidate.target)
            }
            manifest.phase = .committed
            manifest.detail = "時區：\(timezoneResult)；GPS：\(gpsResult)；照片與 XMP 已讀回驗證。"
            try store.finish(manifest)
        } catch {
            if !published.isEmpty {
                let expectedPublished = Dictionary(uniqueKeysWithValues:
                    [(target.path, manifest.candidateIdentity!)] + candidates.compactMap { candidate in
                        manifest.sidecarCandidateIdentities?[candidate.stage.path].map { (candidate.target.path, $0) }
                    })
                let rollback = rollbackPublished(published, candidates: candidates,
                    target: target, photoBackup: photoBackup, plan: plan, expected: expectedPublished)
                manifest.phase = .publicationUnconfirmed
                manifest.detail = "發佈失敗：\(error.localizedDescription)。\(rollback)"
                item.publicationUnconfirmed = true
                try? store.save(manifest)
                throw PhotoError("時區：失敗；GPS：失敗。\(manifest.detail) 交易：\(manifest.id)")
            }
            manifest.phase = .aborted
            manifest.detail = error.localizedDescription
            try? store.finish(manifest)
            throw error
        }
        item.status = .success
        item.detail = "時區：\(timezoneResult)。GPS：\(gpsResult)。照片與對應 XMP 已驗證。"
        if plan != nil {
            item.detail += "\n\(photoChanges.isEmpty && !anySidecarChange ? "原樣輸出" : "副本輸出")：\(target.path)"
        }
        if let photoBackup { item.detail += "\n照片備份：\(photoBackup.path)" }
        if !candidates.isEmpty {
            item.detail += "\n伴隨檔：\(candidates.map { $0.target.lastPathComponent }.joined(separator: ", "))"
        }
    }

    private static let dateFields: Set<String> = ["DateTimeOriginal", "CreateDate", "ModifyDate", "DateCreated"]
    private static func tagName(_ key: String) -> String { String(key.split(separator: ":").last ?? "") }

    private static func xmpAssignments(tags: [String: String], mode: WriteMode,
        timezone: Bool, resultingOffset: (String) -> String, gps: GPSWriteRequest?,
        existingXMPDocument: Bool = false) throws -> [(String, String)] {
        var result: [(String, String)] = []
        if timezone {
            let counterparts = ["DateTimeOriginal": "OffsetTimeOriginal", "DateCreated": "OffsetTimeOriginal",
                "CreateDate": "OffsetTimeDigitized", "ModifyDate": "OffsetTime"]
            for key in tags.keys.sorted() where key.hasPrefix("XMP") && dateFields.contains(tagName(key)) {
                guard let raw = tags[key], let value = jsonString(raw), let field = counterparts[tagName(key)] else {
                    throw PhotoError("XMP 日期欄位無法安全讀取：\(key)。這張照片保持原狀。")
                }
                let desired = resultingOffset(field)
                let parsed = try parseXMPDate(value, key: key)
                if let existing = parsed.offset, mode == .fillMissing {
                    let normalized = existing == "Z" ? "+00:00" : existing
                    guard normalized == desired else {
                        throw PhotoError("時區衝突：\(key) 為 \(existing)，對應 EXIF 為 \(desired)；\(mode == .fillMissing ? "請逐張檢查或明確選擇覆寫。" : "")")
                    }
                } else {
                    let updated = parsed.local + desired
                    if updated != value {
                        let writableKey = MetadataVerifier.canonicalCopyKey(key)
                        if let prior = result.first(where: { $0.0 == writableKey }), prior.1 != updated {
                            throw PhotoError("XMP 同名日期欄位彼此矛盾：\(writableKey)；這張照片保持原狀。")
                        }
                        if !result.contains(where: { $0.0 == writableKey }) {
                            result.append((writableKey, updated))
                        }
                    }
                }
            }
        }
        if let gps {
            let allowed: Set<String> = ["GPSLatitude", "GPSLongitude", "GPSAltitude", "GPSAltitudeRef",
                "GPSVersionID", "GPSDateTime", "GPSTimeStamp", "GPSDateStamp"]
            for (key, raw) in tags where key.hasPrefix("XMP") {
                if key.contains("GPS") || raw.contains("\"GPS") {
                    guard key.hasPrefix("XMP-exif:") && allowed.contains(tagName(key)) else {
                        throw PhotoError("無法安全同步非標準 XMP GPS 欄位 \(key)；這張照片保持原狀。")
                    }
                }
            }
            if !tags.isEmpty || existingXMPDocument {
                let position = gps.coordinate
                result.append(("XMP-exif:GPSLatitude", position.latitude < 0 ? "-\(position.latitudeArgument)" : position.latitudeArgument))
                result.append(("XMP-exif:GPSLongitude", position.longitude < 0 ? "-\(position.longitudeArgument)" : position.longitudeArgument))
                if let altitude = position.altitudeArgument {
                    result.append(("XMP-exif:GPSAltitude", altitude))
                    result.append(("XMP-exif:GPSAltitudeRef", position.altitudeRef ?? "0"))
                } else if gps.overwrite {
                    for tag in ["GPSAltitude", "GPSAltitudeRef"] where tags.keys.contains(where: {
                        MetadataVerifier.canonicalCopyKey($0) == "XMP-exif:\(tag)"
                    }) {
                        result.append(("XMP-exif:\(tag)", ""))
                    }
                }
            }
        }
        return result
    }

    private static func parseXMPDate(_ value: String, key: String) throws -> (local: String, offset: String?) {
        // XMP Date permits minute precision. Preserve its original precision;
        // appending an offset must not invent seconds or move the local clock.
        let pattern = #"^([0-9]{4}[-:][0-9]{2}[-:][0-9]{2}[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]+)?)?)(Z|[+-][0-9]{2}:[0-9]{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let localRange = Range(match.range(at: 1), in: value) else {
            throw PhotoError("XMP 日期格式無法安全更新：\(key)=\(value)。這張照片保持原狀。")
        }
        let offset = Range(match.range(at: 2), in: value).map { String(value[$0]) }
        if let offset, offset != "Z" && !TimeValidation.isOffset(offset) {
            throw PhotoError("XMP 時區超出安全範圍：\(key)=\(value)。")
        }
        return (String(value[localRange]), offset)
    }

    private static func jsonString(_ raw: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? String
    }

    private static func gpsAssignments(_ location: GPSCoordinate, before: PhotoMetadata) -> [(String, String)] {
        var values = [("GPS:GPSLatitude", location.latitudeArgument), ("GPS:GPSLatitudeRef", location.latitudeRef),
            ("GPS:GPSLongitude", location.longitudeArgument), ("GPS:GPSLongitudeRef", location.longitudeRef)]
        if before.gpsVersionID == nil { values.append(("GPS:GPSVersionID", "2.3.0.0")) }
        if let altitude = location.altitudeArgument {
            values += [("GPS:GPSAltitude#", altitude), ("GPS:GPSAltitudeRef#", location.altitudeRef ?? "0")]
        } else {
            values += [("GPS:GPSAltitude#", ""), ("GPS:GPSAltitudeRef#", "")]
        }
        return values
    }

    private static func mutate(_ file: URL, assignments: [(String, String)], tool: ExifTool,
                               cancellation: CancellationToken, priorToolkit: String?) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try fm.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: file.path)
        let preserveToolkit = assignments.contains { $0.0.hasPrefix("XMP") }
            ? ["-XMP-x:XMPToolkit=\(priorToolkit ?? "")"] : []
        let result = try tool.execute(["-charset", "filename=UTF8", "-P", "-overwrite_original_in_place"] +
            assignments.map { tag, value in
                let writable = tag == "XMP-exif:GPSAltitudeRef" ? "\(tag)#" : tag
                return "-\(writable)=\(value)"
            } + preserveToolkit + [file.path],
            timeout: 600, cancellation: cancellation)
        guard result.status == 0 else {
            throw PhotoError("候選檔寫入失敗；原檔保持原狀。\(result.text)")
        }
    }

    private static func verifySidecar(before: ExifTool.SidecarSnapshot, after: ExifTool.SidecarSnapshot,
                                      assignments: [(String, String)], gps: GPSCoordinate?) throws {
        guard after.gpsCheckReliable else { throw PhotoError("寫入後 XMP sidecar 無法可靠讀回。") }
        let allowedChanges = Set(assignments.map(\.0))
        let keys = Set(before.tags.keys).union(after.tags.keys)
        for key in keys where before.tags[key] != after.tags[key] &&
            !allowedChanges.contains(key) && !allowedChanges.contains(MetadataVerifier.canonicalCopyKey(key)) {
            throw PhotoError("XMP sidecar 的非目標欄位變動：\(key)；候選檔已拒絕。")
        }
        try MetadataVerifier.verifyAssignedValues(assignments, in: after.tags)
        if let gps, assignments.contains(where: { $0.0 == "XMP-exif:GPSLatitude" }) {
            try MetadataVerifier.verifyXMPCoordinate(tags: after.tags, coordinate: gps)
        }
    }

    private static func durableBackup(_ source: URL, to backup: URL, expected: FileIdentity) throws {
        let temporary = backup.deletingLastPathComponent().appendingPathComponent(".photo-timezone-backup-\(UUID().uuidString).backup")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try SafeFileTransaction.copyAndSync(source, to: temporary)
        try expected.verify(source)
        try SafeFileTransaction.publishExclusive(temporary, to: backup)
    }

    private static func rollbackPublished(_ published: [URL], candidates: [SidecarCandidate],
                                          target: URL, photoBackup: URL?, plan: DestinationPlan?,
                                          expected: [String: FileIdentity]) -> String {
        var errors: [String] = []
        for file in published.reversed() where FileManager.default.fileExists(atPath: file.path) {
            do {
                guard let pinned = expected[file.path] else { throw PhotoError("缺少發佈身分紀錄") }
                try verifyPublished(pinned, at: file)
                if plan == nil {
                    let backup = file.path == target.path ? photoBackup : candidates.first { $0.target.path == file.path }?.backup
                    guard let backup else { throw PhotoError("缺少備份") }
                    let stage = SafeFileTransaction.temporaryPhoto(beside: file)
                    defer { try? FileManager.default.removeItem(at: stage) }
                    try SafeFileTransaction.copyAndSync(backup, to: stage)
                    try SafeFileTransaction.replace(stage, at: file)
                } else {
                    try FileManager.default.removeItem(at: file)
                    try SafeFileTransaction.syncDirectory(file.deletingLastPathComponent())
                }
            } catch { errors.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        return errors.isEmpty ? "已嘗試回復全部已發佈檔案；請依交易紀錄確認。" :
            "自動回復未完成：\(errors.joined(separator: "; "))。請保留備份並人工檢查。"
    }

    private static func verifyPublished(_ candidate: FileIdentity, at path: URL) throws {
        let visible = try FileIdentity.read(path)
        // rename changes ctime on APFS; preserve the stable inode, byte count,
        // modification time and permissions when identifying the published file.
        guard candidate.device == visible.device, candidate.inode == visible.inode,
              candidate.size == visible.size,
              candidate.modifiedSeconds == visible.modifiedSeconds,
              candidate.modifiedNanoseconds == visible.modifiedNanoseconds,
              candidate.mode & 0o7777 == visible.mode & 0o7777 else {
            throw PhotoError("發佈檔案身分已改變：\(path.path)；請人工檢查。")
        }
    }

    private static func verifyPhotoGPS(_ metadata: PhotoMetadata, coordinate: GPSCoordinate) throws {
        guard let latitudeText = metadata.gpsLatitude, let longitudeText = metadata.gpsLongitude,
              let latitude = Double(latitudeText), let longitude = Double(longitudeText) else {
            throw PhotoError("發佈後無法讀回 EXIF GPS。")
        }
        let actualLatitude = ["S", "SOUTH"].contains(metadata.gpsLatitudeRef?.uppercased() ?? "") ? -abs(latitude) : abs(latitude)
        let actualLongitude = ["W", "WEST"].contains(metadata.gpsLongitudeRef?.uppercased() ?? "") ? -abs(longitude) : abs(longitude)
        guard abs(actualLatitude - coordinate.latitude) < 0.000001,
              abs(actualLongitude - coordinate.longitude) < 0.000001 else {
            throw PhotoError("發佈後 EXIF GPS 座標不符。")
        }
    }
}
