import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One sequential native ExifTool session per job. No shell and no shared globals.
/// Both output channels are independently spooled to disk to avoid pipe deadlocks.
/// Responses require BOTH the ready token and an exit-status token. Sessions are
/// recycled after 128 commands or 64 MiB of spool data and never survive a job.
final class ExifToolSession {
    let url: URL
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var outWriter: FileHandle?
    private var errWriter: FileHandle?
    private var outReader: FileHandle?
    private var errReader: FileHandle?
    private var directory: URL?
    private var completed: DispatchSemaphore?
    private var sequence = 0
    private var outputOffset: UInt64 = 0
    private var errorOffset: UInt64 = 0

    init(url: URL) { self.url = url }
    deinit { stop() }

    func execute(_ arguments: [String], timeout: TimeInterval,
                 cancellation: CancellationToken?) throws -> ProcessOutput {
        lock.lock(); defer { lock.unlock() }
        if cancellation?.isCancelled == true { throw CancellationError() }
        // Line-based native argfiles cannot represent these characters safely.
        guard !arguments.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) else {
            throw PhotoError("This path requires the direct argv transport.")
        }
        if sequence >= 128 || outputOffset + errorOffset > 64 * 1024 * 1024 { stop() }
        if process == nil { try start() }
        guard let process, let input, let outReader, let errReader else { throw PhotoError("ExifTool worker unavailable.") }
        sequence += 1
        let ready = Data("{ready\(sequence)}\n".utf8)
        let statusToken = "PTZ-\(UUID().uuidString)-STATUS-"
        let request = arguments + ["-echo4", statusToken + "${status}", "-execute\(sequence)"]
        do {
            try input.write(contentsOf: Data((request.joined(separator: "\n") + "\n").utf8))
            let started = ProcessInfo.processInfo.systemUptime
            while true {
                if cancellation?.isCancelled == true { throw CancellationError() }
                let outputEnd = try outReader.seekToEnd(), errorEnd = try errReader.seekToEnd()
                guard outputEnd >= outputOffset, errorEnd >= errorOffset,
                      outputEnd - outputOffset <= UInt64(ExifTool.outputLimit),
                      errorEnd - errorOffset <= UInt64(ExifTool.errorLimit) else {
                    throw PhotoError("ExifTool exceeded its bounded output budget; no partial result was accepted.")
                }
                let stdoutTail = try tail(outReader, start: outputOffset, end: outputEnd)
                let stderrTail = String(decoding: try tail(errReader, start: errorOffset, end: errorEnd), as: UTF8.self)
                if stdoutTail.hasSuffix(ready), stderrTail.hasSuffix("\n"),
                   let range = stderrTail.range(of: statusToken, options: .backwards),
                   let status = Int32(stderrTail[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    try outReader.seek(toOffset: outputOffset)
                    let outputLength = Int(outputEnd - outputOffset) - ready.count
                    let stdout = try outReader.read(upToCount: outputLength) ?? Data()
                    try errReader.seek(toOffset: errorOffset)
                    let errorBytes = try errReader.read(upToCount: Int(errorEnd - errorOffset)) ?? Data()
                    let allErrors = String(decoding: errorBytes, as: UTF8.self)
                    guard stdout.count == outputLength,
                          let marker = allErrors.range(of: statusToken, options: .backwards) else {
                        throw PhotoError("Incomplete ExifTool response; candidate was not accepted.")
                    }
                    outputOffset = outputEnd; errorOffset = errorEnd
                    return ProcessOutput(status: status, stdout: stdout,
                        stderr: String(allErrors[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard process.isRunning else { throw PhotoError("ExifTool worker exited before completing its response.") }
                guard ProcessInfo.processInfo.systemUptime - started < timeout else {
                    throw PhotoError("ExifTool timed out; only a disposable candidate may have been changed.")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        } catch {
            // Never reuse a worker after an incomplete or cancelled command.
            stop()
            throw error
        }
    }

    private func tail(_ file: FileHandle, start: UInt64, end: UInt64) throws -> Data {
        let position = max(start, end > 256 ? end - 256 : 0)
        try file.seek(toOffset: position)
        return try file.read(upToCount: Int(end - position)) ?? Data()
    }

    private func start() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("PhotoTimezone-worker-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = temp
        do {
            let out = temp.appendingPathComponent("stdout"), err = temp.appendingPathComponent("stderr")
            guard fm.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  fm.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PhotoError("Cannot create private ExifTool output files.")
            }
            outWriter = try FileHandle(forWritingTo: out); errWriter = try FileHandle(forWritingTo: err)
            outReader = try FileHandle(forReadingFrom: out); errReader = try FileHandle(forReadingFrom: err)
            let child = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = [url.path, "-config", "", "-stay_open", "True", "-@", "-"]
            child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
            child.standardInput = pipe; child.standardOutput = outWriter; child.standardError = errWriter
            child.terminationHandler = { _ in done.signal() }
            try child.run()
            process = child; completed = done; input = pipe.fileHandleForWriting
            try? pipe.fileHandleForReading.close()
            outputOffset = 0; errorOffset = 0; sequence = 0
        } catch { stop(); throw error }
    }

    private func stop() {
        if let process, process.isRunning {
            try? input?.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
            try? input?.close()
            if completed?.wait(timeout: .now() + 0.5) == .timedOut {
                process.terminate()
                if completed?.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
        }
        try? input?.close(); try? outWriter?.close(); try? errWriter?.close()
        try? outReader?.close(); try? errReader?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        process = nil; input = nil; outWriter = nil; errWriter = nil
        outReader = nil; errReader = nil; directory = nil; completed = nil
        sequence = 0; outputOffset = 0; errorOffset = 0
    }
}

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool { count >= suffix.count && self.suffix(suffix.count).elementsEqual(suffix) }
}
