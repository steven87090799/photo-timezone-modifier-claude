import Foundation
import TimezoneCore

/// Optional, explicit delivery. The endpoint and credentials live in memory.
final class CompressionWebhook {
    struct Configuration {
        let url: URL
        let token: String

        init(url text: String, token: String) throws {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
                  token.utf8.count <= 4096, token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
                throw PhotoError("請輸入有效的 HTTPS Webhook 網址與權杖。本機測試可使用 localhost 的 HTTP 網址。")
            }
            self.url = url
            self.token = token
        }
    }

    private enum DeliveryError: LocalizedError {
        case responseTooLarge
        case http(Int)
        case network(URLError.Code)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .responseTooLarge: return "Webhook 回應超過 64 KiB。"
            case .http(let status): return "Webhook 回應 HTTP \(status)。"
            case .network(let code): return "Webhook 連線失敗（\(code.rawValue)）。"
            case .invalidResponse: return "Webhook 回應無效。"
            }
        }

        var isTransient: Bool {
            switch self {
            case .http(let status):
                return [408, 425, 429, 500, 502, 503, 504].contains(status)
            case .network(let code):
                return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(code)
            default:
                return false
            }
        }
    }

    /// Read bounded replies even for file uploads. Each attempt owns its
    /// session, so cancellation and redirects cannot cross into another attempt.
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private static let responseLimit = 64 * 1024
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        private var continuation: CheckedContinuation<Void, Error>?
        // The session serializes its delegate callbacks.
        private var responseBytes = 0
        private var failure: DeliveryError?

        func perform(_ request: URLRequest, file: URL?) async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 120
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if cancelled {
                        lock.unlock()
                        completion.resume(throwing: CancellationError())
                        return
                    }
                    continuation = completion
                    let current = file.map { session.uploadTask(with: request, fromFile: $0) }
                        ?? session.dataTask(with: request)
                    task = current
                    current.resume()
                    lock.unlock()
                }
            } onCancel: {
                self.lock.lock()
                self.cancelled = true
                let current = self.task
                self.lock.unlock()
                current?.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                if !(200..<300).contains(http.statusCode) { failure = .http(http.statusCode) }
                else if http.expectedContentLength > Self.responseLimit { failure = .responseTooLarge }
            } else {
                failure = .invalidResponse
            }
            completionHandler(failure == nil ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if data.count > Self.responseLimit - responseBytes {
                failure = .responseTooLarge
                dataTask.cancel()
                return
            }
            responseBytes += data.count
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let completion = continuation
            let wasCancelled = cancelled
            continuation = nil
            self.task = nil
            lock.unlock()
            if wasCancelled { completion?.resume(throwing: CancellationError()) }
            else if let failure { completion?.resume(throwing: failure) }
            else if let error = error as? URLError { completion?.resume(throwing: DeliveryError.network(error.code)) }
            else if error != nil || task.response == nil { completion?.resume(throwing: DeliveryError.invalidResponse) }
            else { completion?.resume() }
        }
    }

    private func request(_ configuration: Configuration, batchID: String) -> URLRequest {
        var request = URLRequest(url: configuration.url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(batchID, forHTTPHeaderField: "X-Nexpress-Batch")
        if !configuration.token.isEmpty { request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization") }
        return request
    }

    func test(configuration: Configuration) async throws {
        var request = request(configuration, batchID: "test")
        request.timeoutInterval = 8
        request.httpBody = try JSONSerialization.data(withJSONObject: ["app": "NEXPRESS", "version": "3.2.1", "type": "test", "when": ISO8601DateFormatter().string(from: Date())])
        try await Transfer().perform(request, file: nil)
    }

    @MainActor
    func send(item: CompressionItem, configuration: Configuration, batchID: String) async throws {
        guard let result = item.result, let format = item.format else { return }
        try Task.checkCancellation()
        let metadata: [String: Any] = ["app": "NEXPRESS", "version": "3.2.1", "type": "file", "batchId": batchID,
            "fileName": item.outputName, "sourceName": item.source.lastPathComponent,
            "origSize": item.measuredSourceBytes, "compSize": result.bytes, "format": format.mime,
            "ratio": (item.savings ?? 0) * 100, "elapsedSec": item.elapsed,
            "metadataStatus": result.metadataStatus, "timezone": NSNull(), "timeShiftMinutes": NSNull(), "exif": NSNull()]
        let json = try JSONSerialization.data(withJSONObject: metadata)
        let source = result.url, name = item.outputName, mime = format.mime
        let boundary = "PhotoTimezone-" + UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory
        let directory = temporary.appendingPathComponent("PhotoTimezoneWebhook-" + UUID().uuidString)
        try CompressionImages.requireTemporaryCapacity(temporary, bytes: result.bytes, copies: 1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = directory.appendingPathComponent("upload")
        let prepare = Task.detached {
            let pinned = try result.outputIdentity ?? FileIdentity.read(source)
            try pinned.verify(source)
            guard pinned.size == result.bytes, pinned.size <= CompressionImages.maximumFileBytes,
                  FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PhotoError("無法建立安全的 Webhook 暫存檔。")
            }
            let handle = try FileHandle(forWritingTo: body)
            defer { try? handle.close() }
            func append(_ value: String) throws { try handle.write(contentsOf: Data(value.utf8)) }
            try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n")
            try handle.write(contentsOf: json)
            let safeName = name.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            try append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            var remaining = pinned.size
            while remaining > 0 {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !bytes.isEmpty else {
                    throw PhotoError("讀取 Webhook 成品時檔案已變動。")
                }
                try handle.write(contentsOf: bytes)
                remaining -= Int64(bytes.count)
            }
            try pinned.verify(source)
            try append("\r\n--\(boundary)--\r\n")
        }
        try await withTaskCancellationHandler { try await prepare.value } onCancel: { prepare.cancel() }
        var upload = request(configuration, batchID: batchID)
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.setValue("\(batchID)/\(item.id.uuidString)", forHTTPHeaderField: "Idempotency-Key")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                try await Transfer().perform(upload, file: body)
                return
            } catch let error as DeliveryError where error.isTransient && attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
            }
        }
    }

    @MainActor
    func summary(configuration: Configuration, batchID: String, items: [CompressionItem]) async throws {
        var request = request(configuration, batchID: batchID)
        let successful = items.filter { $0.state == .success }
        let failed = items.filter { $0.state == .failed }
        let unsent = successful.filter { $0.webhookStatus?.hasPrefix("傳送失敗") == true }
        let totals = ["files": successful.count, "sent": successful.filter { $0.webhookStatus == "已傳送" }.count,
                      "failed": unsent.count]
        let deadLetters = failed.map { ["fileName": $0.source.lastPathComponent, "reason": "compression_failed"] } +
            unsent.map { ["fileName": $0.outputName, "reason": "delivery_failed"] }
        let payload: [String: Any] = ["app": "NEXPRESS", "version": "3.2.1", "type": "batch_summary", "batchId": batchID,
            "when": ISO8601DateFormatter().string(from: Date()),
            "totals": totals, "deadLetters": deadLetters,
            "total": items.count, "success": successful.count, "failed": failed.count,
            "origSize": successful.reduce(Int64(0)) { $0 + $1.measuredSourceBytes },
            "compSize": successful.reduce(Int64(0)) { $0 + ($1.result?.bytes ?? 0) }]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await Transfer().perform(request, file: nil)
    }
}
