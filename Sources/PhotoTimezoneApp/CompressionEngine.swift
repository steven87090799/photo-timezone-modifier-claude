import AppKit
import Foundation
import SwiftUI
import WebKit
import TimezoneCore

struct CompressionEngineResult {
    let url: URL
    let bytes: Int64
    var sourceBytes: Int64? = nil
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
    @Published private(set) var webView: WKWebView?
    let workDirectory: URL
    private var server: CompressionLocalServer?
    private var loaded = false
    private var idleTask: Task<Void, Never>?
    var idleDelayNanoseconds: UInt64 = 5_000_000_000
    private var releaseRequested = false
    private var progress: [String: (Double, String) -> Void] = [:]
    private var cancellations: [String: CancellationToken] = [:]

    override init() {
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTimezoneCompression-\(UUID().uuidString)", isDirectory: true)
        super.init()
        do { try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false) }
        catch { self.error = error.localizedDescription }
    }

    deinit { server?.stop(); try? FileManager.default.removeItem(at: workDirectory) }

    func loadIfNeeded() {
        guard !loaded, error == nil else { return }
        releaseRequested = false
        do {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(WeakCompressionHandler(self), name: "compression")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            webView = view
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("CompressionWeb")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CompressionWeb")
            let root = bundled.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("engine.html").path) ? $0 : nil } ?? source
            let server = try CompressionLocalServer(root: root, preferredPort: 0)
            self.server = server
            view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/engine.html")!))
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            formats = Set(body["formats"] as? [String] ?? [])
            isReady = !formats.isEmpty
            if !isReady { error = "壓縮編碼器無法啟動。" }
            scheduleIdleRelease()
        } else if type == "progress", let id = body["id"] as? String {
            progress[id]?(body["pct"] as? Double ?? 0, body["status"] as? String ?? "處理中")
        } else if type == "error" { error = body["message"] as? String ?? "壓縮引擎無法啟動。" }
    }

    func perform(source: URL, format: CompressionFormat, quality: Int, preview: Bool,
                 onProgress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> CompressionEngineResult {
        let cancellation = CancellationToken()
        return try await withTaskCancellationHandler {
            try await perform(source: source, format: format, quality: quality, preview: preview,
                              cancellation: cancellation, onProgress: onProgress)
        } onCancel: { cancellation.cancel() }
    }

    func isAvailable(_ format: CompressionFormat) -> Bool {
        format == .jpeg || format == .jxl || (format == .heif && Self.supportsHEIF) || (isReady && formats.contains(format.mime))
    }

    static let supportsHEIF = (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.heic") == true

    func prepare(_ format: CompressionFormat) async throws {
        if format == .jpeg || format == .jxl || format == .heif { return }
        idleTask?.cancel(); idleTask = nil
        loadIfNeeded()
        for _ in 0..<600 {
            try Task.checkCancellation()
            if let error { throw failure(error) }
            if isReady { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw failure("壓縮編碼器載入逾時。")
    }

    private func scheduleIdleRelease() {
        idleTask?.cancel()
        guard cancellations.isEmpty, loaded else { return }
        idleTask = Task { [weak self] in
            guard let delay = self?.idleDelayNanoseconds else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.releaseRuntime()
        }
    }

    private func perform(source: URL, format: CompressionFormat, quality: Int, preview: Bool,
                         cancellation: CancellationToken,
                         onProgress: @escaping (Double, String) -> Void) async throws -> CompressionEngineResult {
        idleTask?.cancel(); idleTask = nil
        guard format != .heif || Self.supportsHEIF else { throw failure("此 Mac 不支援 HEIF 編碼。") }
        let id = UUID().uuidString
        let folder = workDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let stagedSource = folder.appendingPathComponent("source." + source.pathExtension)
        let output = folder.appendingPathComponent("output." + format.fileExtension)
        cancellations[id] = cancellation
        defer { cancellations.removeValue(forKey: id); if releaseRequested { releaseRuntime() } else { scheduleIdleRelease() } }
        do {
            try Task.checkCancellation()
            let sourceBytes = try await Task.detached(priority: .userInitiated) {
                let pinned = try FileIdentity.read(source)
                guard pinned.size <= 256 * 1024 * 1024 else { throw self.failure("來源檔案超過 256 MiB。") }
                try FileManager.default.copyItem(at: source, to: stagedSource)
                try pinned.verify(source)
                return pinned.size
            }.value
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            let depth = await Task.detached { CompressionImages.sourceDepth(stagedSource) }.value
            let highDepthPNG = format == .png && depth > 8 && !preview
            if ![CompressionFormat.jpeg, .jxl, .heif].contains(format) && !highDepthPNG {
                try await prepare(format)
                guard isAvailable(format) else { throw failure("所選格式的編碼器無法使用。") }
            }
            let result: [String: Any]
            if format == .heif || highDepthPNG {
                let native = try await Task.detached(priority: .userInitiated) {
                    try CompressionNative.encode(source: stagedSource, output: output, format: format,
                        quality: quality, preview: preview, cancellation: cancellation)
                }.value
                result = ["width": native.width, "height": native.height, "frames": native.frames,
                          "profileMode": native.originalProfile ? "original" : "srgb"]
            } else if format == .jpeg || format == .jxl {
                onProgress(60, format == .jpeg ? "Jpegli 編碼中" : "JPEG XL 原生編碼中")
                let native = try await Task.detached(priority: .userInitiated) {
                    if format == .jpeg {
                        return try CompressionJPEG.encode(source: stagedSource, output: output, quality: quality,
                                                          preview: preview, cancellation: cancellation)
                    }
                    let jxl = try CompressionJXL.encode(source: stagedSource, output: output, quality: quality,
                                                        preview: preview, cancellation: cancellation)
                    return CompressionJPEG.Result(width: jxl.width, height: jxl.height,
                                                  originalProfile: jxl.originalProfile, frames: jxl.frames)
                }.value
                result = ["width": native.width, "height": native.height, "frames": native.frames,
                          "profileMode": native.originalProfile ? "original" : "srgb"]
            } else {
                guard let webView, let server else { throw failure("所選格式的編碼器尚未就緒。") }
                server.register(id: id, source: stagedSource, output: output)
                progress[id] = onProgress
                defer { server.unregister(id); progress.removeValue(forKey: id) }
                let options: [String: Any] = ["id": id, "name": source.lastPathComponent,
                    "format": format.mime, "quality": quality, "preview": preview,
                    "preserveProfile": format.preservesRGBProfile]
                let raw = try await webView.callAsyncJavaScript("return await window.compressionEngine.perform(options);",
                    arguments: ["options": options], in: nil, contentWorld: .page)
                guard let decoded = raw as? [String: Any] else { throw failure("壓縮引擎沒有回傳完整結果。") }
                result = decoded
            }
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            guard let width = result["width"] as? Int,
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
                        cancellation: cancellation,
                        iccVerifier: format == .jxl ? { file, expected in
                            CompressionJXL.profileMatches(file, expected: expected)
                        } : nil)
                }.value
                if let actualQuality = result["quality"] as? Int, actualQuality != quality {
                    metadata += "；品質 \(quality) 編碼失敗，已以品質 \(actualQuality) 重試（非無損）"
                }
            }
            if depth > 8 && !highDepthPNG && !(format == .jxl && quality == 100) {
                metadata += "；來源 \(depth) 位元像素轉為 8 位元，非無損"
            }
            if highDepthPNG { metadata += "；16 位元 PNG 使用 macOS 原生無損編碼，努力度由系統決定" }
            if let frames = result["frames"] as? Int, frames > 1 { metadata += "；動畫或多頁影像僅輸出第一幀" }
            try? FileManager.default.removeItem(at: stagedSource)
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw failure("壓縮輸出為空。") }
            if Int64(size) > sourceBytes { metadata += "；輸出比來源大，可降低品質或選擇其他格式" }
            return CompressionEngineResult(url: output, bytes: Int64(size), sourceBytes: sourceBytes, width: width,
                height: height, metadataStatus: metadata, frames: result["frames"] as? Int ?? 1)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func cancelAll() {
        cancellations.values.forEach { $0.cancel() }
        webView?.evaluateJavaScript("window.compressionEngine?.cancelAll()")
    }

    func releaseRuntime() {
        guard cancellations.isEmpty else { releaseRequested = true; return }
        releaseRequested = false
        idleTask?.cancel(); idleTask = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "compression")
        webView?.navigationDelegate = nil
        webView = nil
        server?.stop(); server = nil
        loaded = false; isReady = false; error = nil
    }

    func shutdown() {
        cancelAll()
        releaseRuntime()
        server?.stop()
        try? FileManager.default.removeItem(at: workDirectory)
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
    func makeNSView(context: Context) -> WKWebView { host.webView! }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
