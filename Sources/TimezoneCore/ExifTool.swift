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

    func inspect(_ file: URL, cancellation: CancellationToken? = nil, strictOffsets: Bool = true) throws -> (PhotoMetadata, String) {
        let output = try execute([
            "-charset", "filename=UTF8", "-j", "-a", "-G1:4", "-s",
            "-EXIF:DateTimeOriginal", "-EXIF:CreateDate", "-EXIF:ModifyDate",
            "-EXIF:OffsetTimeOriginal", "-EXIF:OffsetTimeDigitized", "-EXIF:OffsetTime",
            "-FileType", "-Error", "-Warning", file.path
        ], timeout: 120, cancellation: cancellation)
        guard output.status == 0 else { throw PhotoError("讀取失敗（\(output.status)）：\(output.text)") }
        guard let entries = try JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]],
              entries.count == 1, let record = entries.first else {
            throw PhotoError("ExifTool 回傳的 JSON 格式不完整。")
        }
        if let error = record["ExifTool:Error"] as? String { throw PhotoError(error) }
        let warnings = [record["ExifTool:Warning"] as? String, output.stderr.isEmpty ? nil : output.stderr]
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
        let metadata = PhotoMetadata(
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
        guard ["JPEG", "TIFF", "ARW"].contains(metadata.fileType ?? "") else {
            throw PhotoError("實際檔案格式不是支援的 JPEG／TIFF／ARW，已略過寫入。")
        }
        return (metadata, warnings)
    }
}

enum FileSafety {
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
