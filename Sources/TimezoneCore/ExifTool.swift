import Foundation
import CryptoKit
import Darwin

struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: String
    var text: String {
        [String(data: stdout, encoding: .utf8) ?? "", stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A bounded command handles one photo. Outputs go to separate temporary files,
/// so neither a full pipe nor an argument-list size limit can deadlock a job.
struct ExifTool {
    let url: URL
    static let inspectionBatchSize = 48
    func execute(_ arguments: [String], timeout: TimeInterval? = nil, cancellation: CancellationToken? = nil) throws -> ProcessOutput {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw PhotoError("此 macOS 缺少 /usr/bin/perl；無法啟動內建的 ExifTool。")
        }
        let temp = fm.temporaryDirectory.appendingPathComponent("PhotoTimezone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        let outURL = temp.appendingPathComponent("stdout")
        let errURL = temp.appendingPathComponent("stderr")
        guard fm.createFile(atPath: outURL.path, contents: nil),
              fm.createFile(atPath: errURL.path, contents: nil) else {
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
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if cancellation?.isCancelled == true { throw CancellationError() }
        try process.run()
        let started = ProcessInfo.processInfo.systemUptime
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            let expired = timeout.map { ProcessInfo.processInfo.systemUptime - started >= $0 } ?? false
            if expired || cancellation?.isCancelled == true {
                // Only read-only callers opt into timeout/cancellation. Mutating
                // commands finish naturally to avoid interrupting a file write.
                process.terminate()
                if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 1)
                }
                if cancellation?.isCancelled == true { throw CancellationError() }
                throw PhotoError("ExifTool 讀取逾時，未進行後續寫入。")
            }
        }
        try out.synchronize()
        try err.synchronize()
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
            "-Make", "-Model", "-LensModel", "-ISO", "-ExposureTime", "-FNumber", "-FocalLength",
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
                ["DateTimeOriginal", "CreateDate", "ModifyDate"].contains(String(key.split(separator: ":").last ?? ""))
            }.mapValues { String(describing: $0) }
        )
        metadata.make = tag("Make")
        metadata.cameraModel = tag("Model")
        metadata.lensModel = tag("LensModel")
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
        return (metadata, warnings)
    }
}

enum FileSafety {
    static func ensureWriteCapacity(_ url: URL, fileSize: Int64?) throws {
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: url.path) else {
            throw PhotoError("相片或資料夾唯讀；請先從記憶卡複製到可寫入的磁碟，再處理副本。")
        }
        let size = try fileSize ?? Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let available, Int64(available) < max(size, 0) * 2 + 16 * 1024 * 1024 {
            throw PhotoError("磁碟可用空間不足以安全建立備份與暫存；未開始寫入此相片。")
        }
    }

    static func ensureRegular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PhotoError("項目不是一般檔案，或是符號連結：\(url.lastPathComponent)")
        }
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
