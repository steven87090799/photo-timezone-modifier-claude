import AppKit
import Foundation
import SwiftUI
import WebKit
import TimezoneCore

struct CompressionEngineResult {
    let url: URL
    let bytes: Int64
    let width: Int
    let height: Int
    let metadataStatus: String
    let frames: Int
}

@MainActor
final class CompressionHost: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var error: String?
    @Published var isReady = false
    @Published var formats: Set<String> = []
    let webView: WKWebView
    let workDirectory: URL
    private var server: CompressionLocalServer?
    private var loaded = false
    private var progress: [String: (Double, String) -> Void] = [:]
    private var cancellations: [String: CancellationToken] = [:]

    override init() {
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTimezoneCompression-\(UUID().uuidString)", isDirectory: true)
        let configuration = WKWebViewConfiguration()
        // The engine has no visible document, cookies or Service Worker cache.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakCompressionHandler(self), name: "compression")
        webView.navigationDelegate = self
        do { try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false) }
        catch { self.error = error.localizedDescription }
    }

    deinit { try? FileManager.default.removeItem(at: workDirectory) }

    func loadIfNeeded() {
        guard !loaded, error == nil else { return }
        do {
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("CompressionWeb")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CompressionWeb")
            let root = bundled.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("engine.html").path) ? $0 : nil } ?? source
            let server = try CompressionLocalServer(root: root, preferredPort: 0)
            self.server = server
            webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/engine.html")!))
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            formats = Set(body["formats"] as? [String] ?? [])
            isReady = !formats.isEmpty
            if !isReady { error = "壓縮編碼器無法啟動。" }
        } else if type == "progress", let id = body["id"] as? String {
            progress[id]?(body["pct"] as? Double ?? 0, body["status"] as? String ?? "處理中")
        } else if type == "error" { error = body["message"] as? String ?? "壓縮引擎無法啟動。" }
    }

    func perform(source: URL, format: CompressionFormat, quality: Int, preview: Bool,
                 onProgress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> CompressionEngineResult {
        guard isReady, let server, formats.contains(format.mime) else { throw failure("所選格式的編碼器尚未就緒。") }
        let id = UUID().uuidString
        let folder = workDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let stagedSource = folder.appendingPathComponent("source." + source.pathExtension)
        let output = folder.appendingPathComponent("output." + format.fileExtension)
        let cancellation = CancellationToken()
        cancellations[id] = cancellation
        defer { cancellations.removeValue(forKey: id) }
        do {
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                let pinned = try FileIdentity.read(source)
                guard pinned.size <= 256 * 1024 * 1024 else { throw self.failure("來源檔案超過 256 MiB。") }
                try FileManager.default.copyItem(at: source, to: stagedSource)
                try pinned.verify(source)
            }.value
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            server.register(id: id, source: stagedSource, output: output)
            progress[id] = onProgress
            defer { server.unregister(id); progress.removeValue(forKey: id) }
            let options: [String: Any] = ["id": id, "name": source.lastPathComponent,
                "format": format.mime, "quality": quality, "preview": preview,
                "preserveProfile": format.preservesRGBProfile]
            let raw = try await webView.callAsyncJavaScript("return await window.compressionEngine.perform(options);",
                arguments: ["options": options], in: nil, contentWorld: .page)
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            guard let result = raw as? [String: Any], let width = result["width"] as? Int,
                  let height = result["height"] as? Int,
                  FileManager.default.fileExists(atPath: output.path) else { throw failure("壓縮引擎沒有回傳完整結果。") }
            var metadata = "預覽使用縮小影像；大小估算供參考"
            if !preview {
                onProgress(95, "保留並驗證中繼資料")
                let preserve = result["profileMode"] as? String == "original"
                let icc = CompressionImages.colorSpace(stagedSource, preserveOriginal: preserve).copyICCData() as Data?
                let developmentTool = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/vendor-exiftool/exiftool")
                let tool = (try? EngineResources.exiftoolURL()) ?? developmentTool
                metadata = try await Task.detached(priority: .userInitiated) {
                    try CompressionMetadataTransfer.preserve(source: stagedSource, output: output,
                        width: width, height: height, profile: icc, originalProfile: preserve, exiftoolURL: tool,
                        cancellation: cancellation)
                }.value
                if let actualQuality = result["quality"] as? Int, actualQuality != quality {
                    metadata += "；品質 \(quality) 編碼失敗，已以品質 \(actualQuality) 重試（非無損）"
                }
            }
            try? FileManager.default.removeItem(at: stagedSource)
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw failure("壓縮輸出為空。") }
            return CompressionEngineResult(url: output, bytes: Int64(size), width: width,
                height: height, metadataStatus: metadata, frames: result["frames"] as? Int ?? 1)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func cancelAll() {
        cancellations.values.forEach { $0.cancel() }
        webView.evaluateJavaScript("window.compressionEngine?.cancelAll()")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false; loaded = false; error = "壓縮引擎已中止；清空後重新開啟程式可再試。"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        decisionHandler(url?.host == "127.0.0.1" && url?.port == server.map { Int($0.port) } ? .allow : .cancel)
    }

    nonisolated private func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoTimezoneCompression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
private final class WeakCompressionHandler: NSObject, WKScriptMessageHandler {
    weak var host: CompressionHost?
    init(_ host: CompressionHost) { self.host = host }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        host?.userContentController(controller, didReceive: message)
    }
}

struct CompressionRuntimeView: NSViewRepresentable {
    let host: CompressionHost
    func makeNSView(context: Context) -> WKWebView { host.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
