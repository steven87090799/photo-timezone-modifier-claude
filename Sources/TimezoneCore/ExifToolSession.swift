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

    func execute(_ command: ExifToolArguments, deadline: DispatchTime,
                 cancellation: CancellationToken?) throws -> ProcessOutput {
        while !lock.try() {
            try checkDeadline(deadline, cancellation: cancellation)
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { lock.unlock() }
        try checkDeadline(deadline, cancellation: cancellation)
        guard command.supportsStayOpen else {
            throw PhotoError("This path requires the direct argv transport.")
        }
        if sequence >= 128 || outputOffset + errorOffset > 64 * 1024 * 1024 { stop() }
        if process == nil { try start() }
        guard let process, let input, let outReader, let errReader else { throw PhotoError("ExifTool worker unavailable.") }
        sequence += 1
        let ready = Data("{ready\(sequence)}\n".utf8)
        let statusToken = "PTZ-\(UUID().uuidString)-STATUS-"
        let request = command.values + ["-echo4", statusToken + "${status}", "-execute\(sequence)"]
        do {
            try send(Data((request.joined(separator: "\n") + "\n").utf8), to: input.fileDescriptor,
                     deadline: deadline, cancellation: cancellation)
            while true {
                try checkDeadline(deadline, cancellation: cancellation)
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
                Thread.sleep(forTimeInterval: 0.01)
            }
        } catch {
            // Never reuse a worker after an incomplete or cancelled command.
            stop()
            throw error
        }
    }

    private func checkDeadline(_ deadline: DispatchTime, cancellation: CancellationToken?) throws {
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard DispatchTime.now() < deadline else {
            throw PhotoError("ExifTool timed out; only a disposable candidate may have been changed.")
        }
    }

    private func send(_ data: Data, to fd: Int32, deadline: DispatchTime, cancellation: CancellationToken?) throws {
        #if canImport(Darwin)
        let sendFlags: Int32 = 0
        #else
        let sendFlags = Int32(MSG_NOSIGNAL)
        #endif
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                try checkDeadline(deadline, cancellation: cancellation)
                let count = writeSocket(fd, base.advanced(by: sent), bytes.count - sent, flags: sendFlags)
                if count > 0 { sent += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                    throw PhotoError("Could not send a complete request to the ExifTool worker.")
                }
                var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&writable, 1, 10)
            }
        }
    }

    private func writeSocket(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int, flags: Int32) -> Int {
        #if canImport(Darwin)
        Darwin.send(fd, bytes, count, flags)
        #else
        Glibc.send(fd, bytes, count, flags)
        #endif
    }

    private func commandChannel() throws -> (reader: FileHandle, writer: FileHandle) {
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        #endif
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, stream, 0, &descriptors) == 0 else {
            throw PhotoError("Cannot create an ExifTool command channel.")
        }
        let reader = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let flags = fcntl(writer.fileDescriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(writer.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(reader.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writer.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw PhotoError("Cannot configure the ExifTool command channel.")
        }
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        guard setsockopt(writer.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw PhotoError("Cannot configure the ExifTool command channel.")
        }
        #endif
        return (reader, writer)
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
            let child = Process(), done = DispatchSemaphore(value: 0)
            let channel = try commandChannel()
            defer { try? channel.reader.close() }
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = [url.path, "-config", "", "-stay_open", "True", "-@", "-"]
            child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
            child.standardInput = channel.reader; child.standardOutput = outWriter; child.standardError = errWriter
            child.terminationHandler = { _ in done.signal() }
            try ChildProcessRegistry.shared.launch(child)
            process = child; completed = done; input = channel.writer
            outputOffset = 0; errorOffset = 0; sequence = 0
        } catch { stop(); throw error }
    }

    private func stop() {
        // EOF ends the pinned stdin worker. Teardown never writes to a stalled reader.
        try? input?.close()
        if let process, process.isRunning {
            if completed?.wait(timeout: .now() + 0.5) == .timedOut {
                process.terminate()
                if completed?.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
        }
        if let process { ChildProcessRegistry.shared.finished(process) }
        try? outWriter?.close(); try? errWriter?.close()
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
