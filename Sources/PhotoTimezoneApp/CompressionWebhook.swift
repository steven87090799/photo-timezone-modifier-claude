import Foundation

/// Optional, explicitly enabled delivery. Credentials are kept only in memory.
final class CompressionWebhook: NSObject, URLSessionTaskDelegate {
    struct Configuration {
        let url: URL
        let token: String
        init(url text: String, token: String) throws {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
                  !token.contains("\r"), !token.contains("\n") else {
                throw NSError(domain: "Webhook", code: 1, userInfo: [NSLocalizedDescriptionKey: "請輸入 HTTPS Webhook 網址；本機測試可使用 localhost 的 HTTP 網址。"])
            }
            self.url = url; self.token = token
        }
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    private func request(_ configuration: Configuration, type: String, batchID: String) -> URLRequest {
        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(batchID, forHTTPHeaderField: "X-Nexpress-Batch")
        if !configuration.token.isEmpty { request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Webhook", code: 2, userInfo: [NSLocalizedDescriptionKey: "伺服器回應 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
    }

    func test(configuration: Configuration) async throws {
        var request = request(configuration, type: "test", batchID: "test")
        request.timeoutInterval = 8
        request.httpBody = try JSONSerialization.data(withJSONObject: ["app": "NEXPRESS", "version": "3.2.1", "type": "test", "when": ISO8601DateFormatter().string(from: Date())])
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    @MainActor
    func send(item: CompressionItem, configuration: Configuration, batchID: String) async throws {
        guard let result = item.result, let format = item.format else { return }
        let metadata: [String: Any] = ["app": "NEXPRESS", "version": "3.2.1", "type": "file", "batchId": batchID,
            "fileName": item.outputName, "sourceName": item.source.lastPathComponent,
            "origSize": item.originalBytes, "compSize": result.bytes, "format": format.mime,
            "ratio": (1 - Double(result.bytes) / Double(max(1, item.originalBytes))) * 100, "elapsedSec": item.elapsed,
            "metadataStatus": result.metadataStatus, "timezone": NSNull(), "timeShiftMinutes": NSNull(), "exif": NSNull()]
        let json = try JSONSerialization.data(withJSONObject: metadata)
        let source = result.url, name = item.outputName, mime = format.mime
        let boundary = "PhotoTimezone-" + UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTimezoneWebhook-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: body) }
        try await Task.detached {
            FileManager.default.createFile(atPath: body.path, contents: nil)
            let handle = try FileHandle(forWritingTo: body)
            defer { try? handle.close() }
            func append(_ value: String) throws { try handle.write(contentsOf: Data(value.utf8)) }
            try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n")
            try handle.write(contentsOf: json)
            let safeName = name.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            try append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { try handle.write(contentsOf: bytes) }
            try append("\r\n--\(boundary)--\r\n")
        }.value
        var upload = request(configuration, type: "file", batchID: batchID)
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for attempt in 0..<3 {
            do { let (_, response) = try await session.upload(for: upload, fromFile: body); try validate(response); return }
            catch { if attempt == 2 { throw error }; try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000) }
        }
    }

    @MainActor
    func summary(configuration: Configuration, batchID: String, items: [CompressionItem]) async throws {
        var request = request(configuration, type: "batch_summary", batchID: batchID)
        let totals: [String: Int] = ["files": items.filter { $0.state == .success }.count,
            "sent": items.filter { $0.webhookStatus == "已傳送" }.count,
            "failed": items.filter { $0.webhookStatus?.hasPrefix("傳送失敗") == true }.count]
        let deadLetters = items.filter { $0.state == .failed }.map { ["fileName": $0.source.lastPathComponent, "reason": $0.error ?? ""] }
        let payload: [String: Any] = ["app": "NEXPRESS", "version": "3.2.1", "type": "batch_summary", "batchId": batchID,
            "when": ISO8601DateFormatter().string(from: Date()),
            "totals": totals, "deadLetters": deadLetters,
            "total": items.count, "success": items.filter { $0.state == .success }.count,
            "failed": items.filter { $0.state == .failed }.count,
            "origSize": items.reduce(Int64(0)) { $0 + $1.originalBytes },
            "compSize": items.reduce(Int64(0)) { $0 + ($1.result?.bytes ?? 0) }]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }
}
