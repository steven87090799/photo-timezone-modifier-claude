import CryptoKit
import Dispatch
import Foundation
import TimezoneCore

private enum CompressionHostError: LocalizedError {
    case missingAssets
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .missingAssets: return "找不到 App 內建的壓縮頁資產。"
        case .socket(let detail): return "無法啟動本機壓縮頁：\(detail)"
        }
    }
}

/// Serves bundled WebKit modules and WASM on loopback. Image access requires a
/// fresh session credential and a job registered by the native engine.
final class CompressionLocalServer {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]

        init?(_ data: Data) {
            guard let head = String(data: data, encoding: .ascii) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1",
                  requestLine[1].hasPrefix("/"),
                  requestLine[1].utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { return nil }
            method = String(requestLine[0])
            path = String(requestLine[1])
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...]
                guard !name.isEmpty,
                      name.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) }),
                      value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                      fields[name] == nil else { return nil }
                fields[name] = value.trimmingCharacters(in: .whitespaces)
            }
            headers = fields
        }
    }

    enum Route: Equatable {
        case asset(path: String, headOnly: Bool)
        case raster(id: String)
        case result(id: String, length: Int)
    }

    enum Rejection: Int, Error {
        case badRequest = 400, forbidden = 403, notFound = 404, lengthRequired = 411
        case tooLarge = 413, invalidImage = 422, conflict = 409, busy = 503

        var message: String {
            switch self {
            case .badRequest: return "Bad request"
            case .forbidden: return "Forbidden"
            case .notFound: return "Not found"
            case .lengthRequired: return "Content length required"
            case .tooLarge: return "Result exceeds the upload limit"
            case .invalidImage: return "Unable to process this image"
            case .conflict: return "This job already has a result"
            case .busy: return "Local compression service is busy"
            }
        }
    }

    struct Budget {
        let connectionLimit: Int
        let uploadLimit: Int
        private(set) var connections = 0
        private(set) var uploadBytes = 0

        mutating func admitConnection() -> Bool {
            guard connections < connectionLimit else { return false }
            connections += 1
            return true
        }

        mutating func closeConnection() { connections -= 1 }

        mutating func reserveUpload(_ bytes: Int) -> Bool {
            guard bytes > 0, bytes <= uploadLimit - uploadBytes else { return false }
            uploadBytes += bytes
            return true
        }

        mutating func releaseUpload(_ bytes: Int) { uploadBytes -= bytes }
    }

    private struct Job {
        let source: URL
        let output: URL
        let format: CompressionFormat
        let preview: Bool
        let cancellation: CancellationToken
    }

    static let maxUploadBytes = 256 * 1024 * 1024

    // Only files loaded by the invisible engine are available over HTTP.
    private static let assets = [
        "/engine.html": "text/html; charset=utf-8",
        "/build-info.json": "application/json",
        "/native-engine.js": "text/javascript; charset=utf-8",
        "/worker.js": "text/javascript; charset=utf-8",
        "/vendor/oxipng.js": "text/javascript; charset=utf-8",
        "/vendor/oxipng_bindings.js": "text/javascript; charset=utf-8",
        "/vendor/squoosh_oxipng_bg.wasm": "application/wasm",
    ]

    let port: UInt16
    let credential = SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    var origin: String { "http://127.0.0.1:\(port)" }
    private let listener: Int32
    private var listenerSource: DispatchSourceRead?
    private let root: URL
    // The queue owns at most one full raster from decode through its send.
    private let imageQueue = DispatchQueue(label: "tw.steven.phototimezone.compression.image")
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var uploads: Set<String> = []
    private var clients: Set<Int32> = []
    private var stopped = false
    private var budget = Budget(connectionLimit: 16, uploadLimit: 512 * 1024 * 1024)

    func register(id: String, source: URL, output: URL, format: CompressionFormat, preview: Bool,
                  cancellation: CancellationToken) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        jobs[id] = Job(source: source, output: output, format: format, preview: preview, cancellation: cancellation)
    }

    func unregister(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        jobs.removeValue(forKey: id)
    }

    private func activeJob(_ id: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[id], !job.cancellation.isCancelled else { return nil }
        return job
    }

    init(root: URL, preferredPort: UInt16) throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("engine.html").path) else {
            throw CompressionHostError.missingAssets
        }
        self.root = root.resolvingSymlinksInPath()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CompressionHostError.socket(String(cString: strerror(errno))) }
        var listening = false
        defer { if !listening { Darwin.close(fd) } }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = preferredPort.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        func bind() -> Int32 {
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if bind() != 0 {
            address.sin_port = 0
            guard preferredPort != 0, bind() == 0 else {
                throw CompressionHostError.socket(String(cString: strerror(errno)))
            }
        }
        guard Darwin.listen(fd, 16) == 0 else { throw CompressionHostError.socket(String(cString: strerror(errno))) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard gotName == 0, Self.setNonblocking(fd) else {
            throw CompressionHostError.socket(String(cString: strerror(errno)))
        }
        listener = fd
        port = UInt16(bigEndian: bound.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd,
            queue: DispatchQueue(label: "tw.steven.phototimezone.compression.accept", qos: .userInitiated))
        listenerSource = source
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        // Close only after the accept handler is finished to avoid fd reuse.
        source.setCancelHandler { Darwin.close(fd) }
        listening = true
        source.resume()
    }

    private static func setNonblocking(_ socket: Int32) -> Bool {
        let flags = fcntl(socket, F_GETFL, 0)
        return flags >= 0 && fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0
            && fcntl(socket, F_SETFD, FD_CLOEXEC) == 0
    }

    func stop() {
        lock.lock()
        stopped = true
        jobs.removeAll()
        // Workers own close(). Shutdown wakes I/O without reusing a live fd.
        for client in clients { Darwin.shutdown(client, SHUT_RDWR) }
        lock.unlock()
        listenerSource?.cancel()
    }

    deinit { stop() }

    private func acceptConnections() {
        for _ in 0..<16 {
            guard listenerSource?.isCancelled != true else { return }
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            var noSignal: Int32 = 1
            guard Self.setNonblocking(client),
                  setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                Darwin.close(client)
                continue
            }
            lock.lock()
            guard !stopped, budget.admitConnection() else {
                lock.unlock()
                Darwin.close(client)
                continue
            }
            clients.insert(client)
            lock.unlock()
            let deadline = DispatchTime.now() + .seconds(60)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                autoreleasepool {
                    defer {
                        lock.lock()
                        clients.remove(client)
                        budget.closeConnection()
                        Darwin.close(client)
                        lock.unlock()
                    }
                    serve(client, deadline: deadline)
                }
            }
        }
    }

    func authorize(_ request: Request) throws -> Route {
        guard request.headers["host"] == "127.0.0.1:\(port)",
              request.headers["origin"].map({ $0 == origin }) ?? true else { throw Rejection.forbidden }
        guard request.headers["transfer-encoding"] == nil else { throw Rejection.badRequest }

        let path = String(request.path.prefix { $0 != "?" })
        if Self.assets[path] != nil, request.method == "GET" || request.method == "HEAD" {
            guard request.headers["content-length"].map({ $0 == "0" }) ?? true else { throw Rejection.badRequest }
            return .asset(path: path, headOnly: request.method == "HEAD")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard request.path == path, parts.count == 4, parts[1] == "native",
              UUID(uuidString: String(parts[3])) != nil else { throw Rejection.notFound }
        let raster = request.method == "GET" && parts[2] == "raster"
        let result = request.method == "POST" && parts[2] == "result"
        guard raster || result else { throw Rejection.notFound }
        guard let presented = request.headers["x-phototimezone-session"], acceptsCredential(presented) else {
            throw Rejection.forbidden
        }
        let id = String(parts[3])
        guard activeJob(id) != nil else { throw Rejection.notFound }
        if raster {
            guard request.headers["content-length"].map({ $0 == "0" }) ?? true else { throw Rejection.badRequest }
            return .raster(id: id)
        }
        guard request.headers["origin"] == origin else { throw Rejection.forbidden }
        guard request.headers["content-type"] == "application/octet-stream" else { throw Rejection.badRequest }
        guard let length = request.headers["content-length"] else { throw Rejection.lengthRequired }
        guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(length), count > 0 else { throw Rejection.badRequest }
        guard count <= Self.maxUploadBytes else { throw Rejection.tooLarge }
        return .result(id: id, length: count)
    }

    private func acceptsCredential(_ presented: String) -> Bool {
        guard presented.utf8.count == credential.utf8.count else { return false }
        return zip(presented.utf8, credential.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func beginUpload(id: String, length: Int) throws -> Job {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[id], !job.cancellation.isCancelled else { throw Rejection.notFound }
        guard !uploads.contains(id), !FileManager.default.fileExists(atPath: job.output.path) else { throw Rejection.conflict }
        guard budget.reserveUpload(length) else { throw Rejection.busy }
        uploads.insert(id)
        return job
    }

    private func endUpload(id: String, length: Int) {
        lock.lock(); defer { lock.unlock() }
        uploads.remove(id)
        budget.releaseUpload(length)
    }

    private func publishUpload(_ staging: URL, id: String, deadline: DispatchTime) throws {
        lock.lock(); defer { lock.unlock() }
        guard DispatchTime.now() < deadline, let job = jobs[id], !job.cancellation.isCancelled else {
            throw Rejection.notFound
        }
        try FileManager.default.moveItem(at: staging, to: job.output)
    }

    private func serve(_ client: Int32, deadline: DispatchTime) {
        do {
            guard let head = readHeader(client, deadline: min(deadline, .now() + .seconds(5))) else { return }
            guard let request = Request(head) else { throw Rejection.badRequest }
            switch try authorize(request) {
            case let .asset(path, headOnly):
                let file = root.appendingPathComponent(String(path.dropFirst())).resolvingSymlinksInPath()
                guard let type = Self.assets[path], file.path.hasPrefix(root.path + "/"),
                      let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw Rejection.notFound }
                respond(client, deadline: deadline, type: type, body: data, headOnly: headOnly)
            case let .raster(id):
                try imageQueue.sync {
                    guard DispatchTime.now() < deadline, let job = activeJob(id) else { throw Rejection.notFound }
                    let raster = try CompressionImages.raster(job.source, maxPixel: job.preview ? 900 : 0,
                        preserveOriginal: job.format.preservesRGBProfile, preserveDepth: job.format == .png && !job.preview)
                    guard !job.cancellation.isCancelled else { throw CancellationError() }
                    respond(client, deadline: deadline, type: "application/octet-stream", body: raster.bytes,
                            headers: ["X-Image-Width": String(raster.width), "X-Image-Height": String(raster.height),
                                      "X-Profile-Mode": raster.originalProfile ? "original" : "srgb",
                                      "X-Frame-Count": String(raster.frames)])
                }
            case let .result(id, length):
                let job = try beginUpload(id: id, length: length)
                defer { endUpload(id: id, length: length) }
                var data = Data(count: length)
                guard data.withUnsafeMutableBytes({
                    readExactly(client, into: $0, deadline: deadline, cancellation: job.cancellation)
                }) else { return }
                let staging = job.output.deletingLastPathComponent().appendingPathComponent(".upload-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                try data.write(to: staging, options: .withoutOverwriting)
                try publishUpload(staging, id: id, deadline: deadline)
                respond(client, deadline: deadline, body: Data("OK".utf8))
            }
        } catch let rejection as Rejection {
            respond(client, deadline: deadline, status: rejection.rawValue, body: Data(rejection.message.utf8))
        } catch is CancellationError {
            return
        } catch {
            respond(client, deadline: deadline, status: Rejection.invalidImage.rawValue,
                    body: Data("本機壓縮服務無法處理這張影像。".utf8))
        }
    }

    private func readHeader(_ client: Int32, deadline: DispatchTime) -> Data? {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        let headerLimit = 16 * 1024
        while head.count < headerLimit {
            let allowance = min(buffer.count, headerLimit - head.count)
            // Peek so recv never consumes body bytes before the request is authorized.
            let count = buffer.withUnsafeMutableBytes {
                receive(client, into: $0.baseAddress!, count: allowance,
                        flags: MSG_PEEK, deadline: deadline, cancellation: nil)
            }
            guard count > 0 else { return nil }
            let oldCount = head.count
            head.append(contentsOf: buffer.prefix(count))
            let end = head.range(of: separator, in: max(0, oldCount - 3)..<head.count)
            let consume = (end?.upperBound ?? head.count) - oldCount
            guard buffer.withUnsafeMutableBytes({
                readExactly(client, into: UnsafeMutableRawBufferPointer(rebasing: $0[..<consume]), deadline: deadline)
            }) else { return nil }
            if let end { return head.prefix(end.lowerBound) }
        }
        return nil
    }

    private func receive(_ client: Int32, into buffer: UnsafeMutableRawPointer, count: Int, flags: Int32 = 0,
                         deadline: DispatchTime, cancellation: CancellationToken?) -> Int {
        while DispatchTime.now() < deadline, cancellation?.isCancelled != true {
            let received = Darwin.recv(client, buffer, count, flags)
            if received >= 0 { return received }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { break }
            var readable = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            _ = poll(&readable, 1, 50)
        }
        return -1
    }

    private func readExactly(_ client: Int32, into bytes: UnsafeMutableRawBufferPointer,
                             deadline: DispatchTime, cancellation: CancellationToken? = nil) -> Bool {
        guard let base = bytes.baseAddress else { return bytes.isEmpty }
        var offset = 0
        while offset < bytes.count {
            let count = receive(client, into: base.advanced(by: offset), count: bytes.count - offset,
                                deadline: deadline, cancellation: cancellation)
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private func respond(_ client: Int32, deadline: DispatchTime, status: Int = 200,
                         type: String = "text/plain; charset=utf-8", body: Data,
                         headOnly: Bool = false, headers: [String: String] = [:]) {
        let reason = Rejection(rawValue: status)?.message ?? "OK"
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nCross-Origin-Resource-Policy: same-origin\r\n\(extra)Connection: close\r\n\r\n"
        if sendAll(client, Data(header.utf8), deadline: deadline), !headOnly {
            _ = sendAll(client, body, deadline: deadline)
        }
    }

    private func sendAll(_ client: Int32, _ data: Data, deadline: DispatchTime) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return bytes.isEmpty }
            var sent = 0
            while sent < bytes.count, DispatchTime.now() < deadline {
                let count = Darwin.send(client, base.advanced(by: sent), bytes.count - sent, 0)
                if count > 0 { sent += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
                var writable = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
                _ = poll(&writable, 1, 50)
            }
            return sent == bytes.count
        }
    }
}
