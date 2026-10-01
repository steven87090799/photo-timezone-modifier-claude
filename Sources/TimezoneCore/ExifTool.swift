import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: String
    var text: String {
        [String(data: stdout.prefix(16384), encoding: .utf8) ?? "", stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A bounded command handles one photo. Outputs go to separate temporary files,
/// so neither a full pipe nor an argument-list size limit can deadlock a job.
final class ExifTool {
    let url: URL
    static let outputLimit = 16 * 1024 * 1024
    static let errorLimit = 256 * 1024
    private let session: ExifToolSession?
    init(url: URL, persistent: Bool = false) {
        self.url = url
        self.session = persistent ? ExifToolSession(url: url) : nil
    }
    static let inspectionBatchSize = 48
    struct Snapshot {
        let metadata: PhotoMetadata
        let warnings: String
        let embeddedTags: [String: String]
    }
    func execute(_ arguments: [String], timeout: TimeInterval? = nil, cancellation: CancellationToken? = nil) throws -> ProcessOutput {
        if let session, !arguments.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) {
            return try session.execute(arguments, timeout: timeout ?? 120, cancellation: cancellation)
        }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw PhotoError("此 macOS 缺少 /usr/bin/perl；無法啟動內建的 ExifTool。")
        }
        let temp = fm.temporaryDirectory.appendingPathComponent("PhotoTimezone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let outURL = temp.appendingPathComponent("stdout")
        let errURL = temp.appendingPathComponent("stderr")
        guard fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PhotoError("無法建立 ExifTool 暫存輸出。")
        }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // -config must be first. Disable external user config and Perl injection
        // environment variables to keep the bundled engine reproducible.
        process.arguments = [url.path, "-config", ""] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if cancellation?.isCancelled == true { throw CancellationError() }
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            let expired = timeout.map { ProcessInfo.processInfo.systemUptime - started >= $0 } ?? false
            let outputBytes = try out.offset(), errorBytes = try err.offset()
            let tooLarge = outputBytes > UInt64(Self.outputLimit) || errorBytes > UInt64(Self.errorLimit)
            if expired || tooLarge || cancellation?.isCancelled == true {
                // A timeout/cancellation is safe only for read-only commands
                // or writes to disposable candidates, never an original.
                process.terminate()
                if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 1)
                }
                process.waitUntilExit()
                if cancellation?.isCancelled == true { throw CancellationError() }
                if tooLarge { throw PhotoError("ExifTool output exceeds the metadata budget; no result was accepted.") }
                throw PhotoError("ExifTool 執行逾時，已停止這張照片的候選處理；原檔未更動。")
            }
        }
        let stdoutSize = try out.offset()
        let stderrSize = try err.offset()
        guard stdoutSize <= UInt64(Self.outputLimit), stderrSize <= UInt64(Self.errorLimit) else {
            throw PhotoError("ExifTool output exceeds the bounded metadata budget; original not changed.")
        }
        return ProcessOutput(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: outURL),
            stderr: (try String(contentsOf: errURL, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func validateVersion() throws {
        let result = try execute(["-ver"], timeout: 15)
        let actual = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, actual == EngineResources.version else {
            throw PhotoError("ExifTool 版本不符或啟動失敗；預期 \(EngineResources.version)。\(result.text)")
        }
    }

    private var inspectionArguments: [String] {
        [
            "-charset", "filename=UTF8", "-j", "-a", "-G1:4", "-s",
            "-EXIF:DateTimeOriginal", "-EXIF:CreateDate", "-EXIF:ModifyDate",
            "-EXIF:OffsetTimeOriginal", "-EXIF:OffsetTimeDigitized", "-EXIF:OffsetTime",
            "-XMP-exif:DateTimeOriginal", "-XMP-xmp:CreateDate", "-XMP-xmp:ModifyDate", "-XMP-photoshop:DateCreated",
            "-EXIF:SubSecTimeOriginal", "-EXIF:SubSecTimeDigitized", "-EXIF:SubSecTime",
            "-Make", "-Model", "-SerialNumber", "-LensModel", "-LensSpec", "-Lens", "-LensID", "-LensType", "-LensInfo", "-ISO", "-ExposureTime", "-FNumber", "-FocalLength",
            "-ExifImageWidth", "-ExifImageHeight", "-ImageWidth", "-ImageHeight", "-FileSize#",
            "-FileType", "-Error", "-Warning"
        ]
    }

    func inspect(_ file: URL, cancellation: CancellationToken? = nil, strictOffsets: Bool = true) throws -> (PhotoMetadata, String) {
        let output = try execute(inspectionArguments + [file.path], timeout: 120, cancellation: cancellation)
        guard output.status == 0 else { throw PhotoError("讀取失敗（\(output.status)）：\(output.text)") }
        guard let entries = try JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]],
              entries.count == 1, let record = entries.first else {
            throw PhotoError("ExifTool 回傳的 JSON 格式不完整。")
        }
        return try decode(record, stderr: output.stderr, strictOffsets: strictOffsets)
    }

    /// Bounded argv batches avoid both shell/argfile quoting and one process per
    /// photo during discovery. A nonzero status may still contain good records;
    /// map by SourceFile (never response order) and surface errors per photo.
    func inspectBatch(_ files: [URL], cancellation: CancellationToken) throws -> [String: Result<(PhotoMetadata, String), Error>] {
        guard files.count <= Self.inspectionBatchSize else { throw PhotoError("掃描批次超過上限。") }
        guard !files.isEmpty else { return [:] }
        // 48 POSIX paths are bounded, with an additional UTF-8 byte guard.
        guard files.reduce(0, { $0 + $1.path.utf8.count + 1 }) < 96 * 1024 else {
            throw PhotoError("檔案路徑總長超過安全掃描上限。")
        }
        for file in files { try FileSafety.ensureRegular(file) }
        let output = try execute(inspectionArguments + files.map(\.path), timeout: 120, cancellation: cancellation)
        guard let entries = try JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]] else {
            throw PhotoError("批次掃描回傳不完整：\(output.text)")
        }
        let expected = Set(files.map(\.path))
        var results: [String: Result<(PhotoMetadata, String), Error>] = [:]
        for record in entries {
            guard let path = record["SourceFile"] as? String, expected.contains(path) else { continue }
            if results[path] != nil {
                results[path] = .failure(PhotoError("ExifTool 回傳重複路徑，請重新掃描。"))
                continue
            }
            // JSON -Warning/-Error belongs to each file. Do not attribute the
            // whole batch's stderr to every good photo.
            results[path] = Result { try decode(record, stderr: "", strictOffsets: true) }
        }
        for file in files where results[file.path] == nil {
            results[file.path] = .failure(PhotoError("未收到此相片的掃描結果（狀態 \(output.status)）：\(output.stderr)"))
        }
        // Fail closed if the process failed without a per-file error explaining
        // it. A partial JSON result must never masquerade as a successful scan.
        if output.status != 0 && !results.values.contains(where: { if case .failure = $0 { return true }; return false }) {
            throw PhotoError("批次掃描異常結束（\(output.status)）：\(output.stderr)")
        }
        return results
    }

    /// Compare every readable embedded tag, including unknown tags, while
    /// excluding file-system/derived fields whose values depend on the path.
    /// This is a metadata invariant, not a claim that ExifTool rewrites zero
    /// non-metadata bytes or can see undocumented maker-note internals.
    func embeddedMetadata(_ file: URL, cancellation: CancellationToken? = nil) throws -> [String: String] {
        try snapshot(file, cancellation: cancellation).embeddedTags
    }

    /// One complete read supplies both the preview fields and the invariant
    /// check. This removes two ExifTool launches per changed photo without
    /// weakening the per-photo comparison or transactional write path.
    func snapshot(_ file: URL, cancellation: CancellationToken? = nil, strictOffsets: Bool = true) throws -> Snapshot {
        let output = try execute(["-charset", "filename=UTF8", "-j", "-a", "-G1:4", "-s", "-n", "-U", "-struct", file.path],
                                 timeout: 120, cancellation: cancellation)
        guard output.status == 0,
              let entries = try JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]],
              entries.count == 1, let record = entries.first else {
            throw PhotoError("無法完整讀取內嵌中繼資料：\(output.text)")
        }
        if let error = record["ExifTool:Error"] { throw PhotoError("中繼資料讀取失敗：\(error)") }
        var (metadata, warnings) = try decode(record, stderr: output.stderr, strictOffsets: strictOffsets)
        metadata.fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        var result: [String: String] = [:]
        for (key, value) in record {
            let group = key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            if key == "SourceFile" || ["File", "System", "Composite", "ExifTool"].contains(group) { continue }
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            result[key] = String(decoding: data, as: UTF8.self)
        }
        return Snapshot(metadata: metadata, warnings: warnings, embeddedTags: result)
    }

    /// Test-only byte oracle; the production write path does not read or hash thumbnails.
    func thumbnailBytes(_ file: URL) throws -> Data {
        let output = try execute(["-m", "-b", "-ThumbnailImage", file.path], timeout: 120)
        guard output.status == 0, !output.stdout.isEmpty else {
            throw PhotoError("無法驗證內建縮圖內容；原檔未更動。\n\(output.text)")
        }
        return output.stdout
    }

    struct SidecarSnapshot {
        let url: URL
        let identity: FileIdentity
        let dates: [String: String]
        let warning: String
        func issues(for photo: PhotoMetadata) -> [String] {
            var result = TimeValidation.issues(photo, dates: dates).map { "\(url.lastPathComponent): \($0)" }
            if !warning.isEmpty { result.append(warning) }
            return result
        }
    }

    func readSidecar(_ file: URL, cancellation: CancellationToken? = nil) throws -> SidecarSnapshot {
        let identity = try FileIdentity.read(file)
        guard identity.size <= 8 * 1024 * 1024 else {
            return SidecarSnapshot(url: file, identity: identity, dates: [:],
                warning: "XMP sidecar exceeds the 8 MiB diagnostic budget; copied without rewriting: \(file.lastPathComponent)")
        }
        let output = try execute(["-j", "-G1:4", "-s", "-XMP-exif:DateTimeOriginal", "-XMP-xmp:CreateDate",
            "-XMP-xmp:ModifyDate", "-XMP-photoshop:DateCreated", file.path], timeout: 120, cancellation: cancellation)
        try identity.verify(file)
        guard output.status == 0,
              let records = try JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]],
              records.count == 1, let record = records.first else {
            return SidecarSnapshot(url: file, identity: identity, dates: [:],
                warning: "XMP sidecar could not be diagnosed; it was not rewritten: \(file.lastPathComponent)")
        }
        let dates = record.filter { $0.key.hasPrefix("XMP") }.mapValues { String(describing: $0) }
        return SidecarSnapshot(url: file, identity: identity, dates: dates, warning: output.stderr)
    }

    private func decode(_ record: [String: Any], stderr: String, strictOffsets: Bool) throws -> (PhotoMetadata, String) {
        if let error = record["ExifTool:Error"] as? String { throw PhotoError(error) }
        let warnings = [record["ExifTool:Warning"] as? String, stderr.isEmpty ? nil : stderr]
            .compactMap { $0 }.joined(separator: "\n")
        let offsetNames: Set<String> = ["OffsetTimeOriginal", "OffsetTimeDigitized", "OffsetTime"]
        if strictOffsets {
            // Reject nonstandard or duplicate instances instead of silently
            // treating them as missing and letting EXIF's broad writes overwrite.
            for key in record.keys {
                if let name = key.split(separator: ":").last, offsetNames.contains(String(name)),
                   key != "ExifIFD:\(name)" {
                    throw PhotoError("時區標籤位於非標準位置或重複出現（\(key)）；未寫入，請先檢查此照片。")
                }
            }
        }
        func text(_ name: String) -> String? {
            guard let value = record[name] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        func tag(_ name: String) -> String? {
            let key = record.keys.filter { $0.split(separator: ":").last == Substring(name) }.sorted().first
            guard let key, let value = record[key] else { return nil }
            let result = String(describing: value)
            return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
        }
        var metadata = PhotoMetadata(
            dateTimeOriginal: text("ExifIFD:DateTimeOriginal"),
            offsetOriginal: text("ExifIFD:OffsetTimeOriginal"),
            offsetDigitized: text("ExifIFD:OffsetTimeDigitized"),
            offsetTime: text("ExifIFD:OffsetTime"),
            fileType: text("File:FileType"),
            createDate: text("ExifIFD:CreateDate"),
            modifyDate: text("IFD0:ModifyDate"),
            dateTags: record.filter { key, _ in
                ["DateTimeOriginal", "CreateDate", "ModifyDate", "DateCreated", "SubSecTimeOriginal", "SubSecTimeDigitized", "SubSecTime"].contains(String(key.split(separator: ":").last ?? ""))
            }.mapValues { String(describing: $0) }
        )
        metadata.make = tag("Make")
        metadata.cameraModel = tag("Model")
        metadata.cameraSerialNumber = tag("SerialNumber")
        // Preserve upstream display-only lens fallbacks; never write derived IDs.
        for name in ["LensModel", "LensSpec", "Lens", "LensID", "LensType"] {
            if let value = tag(name) {
                metadata.lensModel = value
                metadata.lensModelSource = name == "LensID" ? "LensID (ExifTool)" : name
                break
            }
        }
        metadata.lensInfo = tag("LensInfo")
        metadata.iso = tag("ISO")
        metadata.exposureTime = tag("ExposureTime")
        metadata.aperture = tag("FNumber")
        metadata.focalLength = tag("FocalLength")
        metadata.imageWidth = tag("ExifImageWidth") ?? tag("ImageWidth")
        metadata.imageHeight = tag("ExifImageHeight") ?? tag("ImageHeight")
        metadata.fileSize = tag("FileSize").flatMap(Int64.init)
        guard ["JPEG", "TIFF", "ARW"].contains(metadata.fileType ?? "") else {
            throw PhotoError("實際檔案格式不是支援的 JPEG／TIFF／ARW，已略過寫入。")
        }
        metadata.compatibilityIssues = TimeValidation.issues(metadata)
        return (metadata, warnings)
    }
}
