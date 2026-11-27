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
    var outputIdentity: FileIdentity? = nil
    var developedSource: URL? = nil
    var rawDecoder: RAWDecoder? = nil
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
    private var temporaryBytesInFlight: Int64 = 0
    private var retainedResults: [URL: Int64] = [:]
    private var retainedBytes: Int64 = 0
    private struct WebJob {
        let completion: CheckedContinuation<Any, Error>
        let timeout: Task<Void, Never>
    }
    private var webJobs: [String: WebJob] = [:]

    override init() {
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTimezoneCompression-\(UUID().uuidString)", isDirectory: true)
        super.init()
        do { try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700]) }
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
            view.load(URLRequest(url: URL(string: server.origin + "/engine.html")!))
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let server, origin.protocol == "http", origin.host == "127.0.0.1", origin.port == Int(server.port),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            formats = Set(body["formats"] as? [String] ?? [])
            isReady = !formats.isEmpty
            if !isReady { error = "壓縮編碼器無法啟動。" }
            scheduleIdleRelease()
        } else if type == "progress", let id = body["id"] as? String {
            progress[id]?(body["pct"] as? Double ?? 0, body["status"] as? String ?? "處理中")
        } else if type == "error" { error = body["message"] as? String ?? "壓縮引擎無法啟動。" }
    }

    func perform(source: URL, format: CompressionFormat, quality: Int, preview: Bool, rawDecoder: RAWDecoder = .version9,
                 onProgress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> CompressionEngineResult {
        let cancellation = CancellationToken()
        return try await withTaskCancellationHandler {
            try await perform(source: source, format: format, quality: quality, preview: preview,
                              rawDecoder: rawDecoder, cancellation: cancellation, onProgress: onProgress)
        } onCancel: { cancellation.cancel() }
    }

    func isAvailable(_ format: CompressionFormat) -> Bool {
        switch format {
        case .heif: return Self.supportsHEIF
        case .avif: return Self.supportsAVIF
        case .png: return isReady && formats.contains(format.mime)
        default: return true
        }
    }

    private static let imageIOFormats = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    static let supportsHEIF = imageIOFormats.contains("public.heic")
    static let supportsAVIF = imageIOFormats.contains("public.avif")

    func prepare(_ format: CompressionFormat) async throws {
        if format != .png {
            guard isAvailable(format) else { throw failure("此 Mac 不支援 \(format.rawValue) 編碼。") }
            return
        }
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
                         rawDecoder: RAWDecoder,
                         cancellation: CancellationToken,
                         onProgress: @escaping (Double, String) -> Void) async throws -> CompressionEngineResult {
        idleTask?.cancel(); idleTask = nil
        if format != .png { try await prepare(format) }
        let sizeHint = try FileIdentity.read(source).size
        guard sizeHint <= CompressionImages.maximumFileBytes else { throw failure("來源檔案超過 256 MiB。") }
        // Reserve output, metadata rewrite and, for RAW, the developed TIFF.
        let reserve = sizeHint + CompressionImages.maximumFileBytes * (CompressionRAW.accepts(source) ? 4 : 2)
        if retainedBytes + temporaryBytesInFlight + reserve > 8 * 1024 * 1024 * 1024 {
            retainedResults = retainedResults.filter { FileManager.default.fileExists(atPath: $0.key.path) }
            retainedBytes = retainedResults.values.reduce(0, +)
        }
        guard retainedBytes + temporaryBytesInFlight + reserve <= 8 * 1024 * 1024 * 1024 else {
            throw failure("壓縮暫存已達 8 GiB，請先儲存並清除部分成品。")
        }
        try CompressionImages.requireTemporaryCapacity(workDirectory, bytes: temporaryBytesInFlight + reserve, copies: 1)
        temporaryBytesInFlight += reserve
        defer { temporaryBytesInFlight -= reserve }
        let id = UUID().uuidString
        let folder = workDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let stagedInput = folder.appendingPathComponent("source." + source.pathExtension)
        var stagedSource = stagedInput
        let output = folder.appendingPathComponent("output." + format.fileExtension)
        cancellations[id] = cancellation
        defer { cancellations.removeValue(forKey: id); if releaseRequested { releaseRuntime() } else { scheduleIdleRelease() } }
        do {
            try Task.checkCancellation()
            let sourceIdentity = try await Task.detached(priority: .userInitiated) {
                let pinned = try FileIdentity.read(source)
                guard pinned.size == sizeHint else { throw self.failure("來源檔案在暫存前已變動。") }
                if !preview { try CompressionPhotoReader.requireEmbeddedMetadataOnly(source) }
                try FileManager.default.copyItem(at: source, to: stagedInput)
                _ = try FileIdentity.read(stagedInput)
                guard FileManager.default.contentsEqual(atPath: source.path, andPath: stagedInput.path) else {
                    throw self.failure("來源暫存副本的位元組核對失敗；已停止輸出。")
                }
                try pinned.verify(source)
                return pinned
            }.value
            let sourceBytes = sourceIdentity.size
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            let developmentTool = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/vendor-exiftool/exiftool")
            let tool = (try? EngineResources.exiftoolURL()) ?? developmentTool
            let isRAW = await Task.detached { CompressionRAW.isRAW(stagedInput) }.value
            if !isRAW && CompressionRAW.accepts(stagedInput) {
                throw PhotoError("macOS 無法辨識這張 RAW；相機型號或 RAW 壓縮模式可能尚未支援。")
            }
            if isRAW {
                onProgress(15, "\(rawDecoder.rawValue) 顯影中")
                let developed = folder.appendingPathComponent("developed.tiff")
                try await Task.detached(priority: .userInitiated) {
                    let rawOrientation = try RAWMetadataTransfer.orientation(stagedInput, exiftoolURL: tool, cancellation: cancellation)
                    let size = try CompressionRAW.develop(source: stagedInput, output: developed, decoder: rawDecoder,
                        sixteenBit: !preview && (format == .png || (format == .jxl && quality == 100)),
                        cancellation: cancellation, maxPixel: preview ? 900 : 0, orientation: rawOrientation)
                    if !preview {
                        try RAWMetadataTransfer.prepare(source: stagedInput, developed: developed,
                            width: size.width, height: size.height, exiftoolURL: tool, cancellation: cancellation)
                    }
                }.value
                stagedSource = developed
            }
            // All later stages read this immutable RGB source, including lossless verification.
            let encodingSource = stagedSource
            let depth = try await Task.detached {
                if preview { return try CompressionImages.sourceDepth(encodingSource) }
                return try CompressionValidation.sourceDepth(encodingSource, format: format, quality: quality)
            }.value
            let orientation: Int
            if !preview && (format == .jpeg || format == .heif) {
                orientation = try await Task.detached { try CompressionMetadataTransfer.exifOrientation(stagedSource, exiftoolURL: tool) }.value
            } else { orientation = 1 }
            let highDepthPNG = format == .png && depth > 8 && !preview
            if format == .png && !highDepthPNG {
                try await prepare(format)
                guard isAvailable(format) else { throw failure("所選格式的編碼器無法使用。") }
            }
            let result: [String: Any]
            if [.heif, .webp, .avif].contains(format) || highDepthPNG {
                onProgress(60, highDepthPNG ? "16 位元 PNG 編碼中" : "\(format.rawValue) 原生編碼中")
                let native = try await Task.detached(priority: .userInitiated) {
                    try CompressionNative.encode(source: stagedSource, output: output, format: format,
                        quality: quality, preview: preview, cancellation: cancellation, orientation: orientation)
                }.value
                result = ["width": native.width, "height": native.height, "frames": native.frames,
                          "profileMode": native.originalProfile ? "original" : "srgb"]
            } else if format == .jpeg || format == .jxl {
                onProgress(60, format == .jpeg ? "Jpegli 編碼中" : "JPEG XL 原生編碼中")
                let native = try await Task.detached(priority: .userInitiated) {
                    if format == .jpeg {
                        return try CompressionJPEG.encode(source: stagedSource, output: output, quality: quality,
                                                          preview: preview, cancellation: cancellation, orientation: orientation)
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
                if cancellation.isCancelled { throw CancellationError() }
                server.register(id: id, source: stagedSource, output: output, format: format, preview: preview,
                                cancellation: cancellation)
                progress[id] = onProgress
                defer { server.unregister(id); progress.removeValue(forKey: id) }
                let options: [String: Any] = ["id": id, "format": format.mime, "quality": quality, "preview": preview]
                let raw = try await runWebJob(id: id, view: webView, options: options, credential: server.credential,
                                              preview: preview, cancellation: cancellation)
                guard let decoded = raw as? [String: Any] else { throw failure("壓縮引擎沒有回傳完整結果。") }
                result = decoded
            }
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            guard let width = result["width"] as? Int,
                  let height = result["height"] as? Int, let encoded = try? FileIdentity.read(output),
                  (1...CompressionImages.maximumFileBytes).contains(encoded.size) else {
                throw failure("壓縮結果不完整或超過 256 MiB。")
            }
            var metadata = "預覽使用縮小影像；大小估算供參考"
            if !preview {
                onProgress(95, "保留並驗證中繼資料")
                // RAW was explicitly developed in sRGB, including the AVIF
                // encoder's sRGB path. Its generated ICC therefore matches.
                let preserve = isRAW || result["profileMode"] as? String == "original"
                let icc = CompressionImages.colorSpace(stagedSource, preserveOriginal: preserve).copyICCData() as Data?
                metadata = try await Task.detached(priority: .userInitiated) {
                    try CompressionMetadataTransfer.preserve(source: stagedSource, output: output,
                        width: width, height: height, profile: icc, originalProfile: preserve, exiftoolURL: tool,
                        cancellation: cancellation,
                        iccVerifier: format == .jxl ? { file, expected in
                            CompressionJXL.profileMatches(file, expected: expected)
                        } : nil, preservePhotoEXIF: format == .jpeg || format == .heif)
                }.value
                try await Task.detached(priority: .userInitiated) {
                    try CompressionValidation.verifyOutput(output, width: width, height: height)
                    if format == .png || (format == .jxl && quality == 100) {
                        try CompressionValidation.verifyLosslessOutput(source: stagedSource, output: output)
                    }
                    try FileExport.preserveConvertedImageAttributes(from: source, to: output)
                    try sourceIdentity.verify(source)
                    try CompressionPhotoReader.requireEmbeddedMetadataOnly(source)
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
            if isRAW {
                let transfer = preview ? "縮小預覽，未複製中繼資料" : "標準拍攝資訊已核對；RAW 私有資料與修圖設定保留在原件"
                metadata = "\(rawDecoder.rawValue) 顯影為 \(depth) 位元 sRGB；\(transfer)；" + metadata
                if format == .png || (format == .jxl && quality == 100) {
                    metadata += "；無損僅指顯影後 RGB 像素，不能取代 RAW"
                }
            } else { try? FileManager.default.removeItem(at: stagedSource) }
            if isRAW { try? FileManager.default.removeItem(at: stagedInput) }
            let identity = try FileIdentity.read(output)
            let size = identity.size
            guard (1...CompressionImages.maximumFileBytes).contains(size) else { throw failure("壓縮輸出為空或超過 256 MiB。") }
            let stored = isRAW ? try size + FileIdentity.read(stagedSource).size : size
            retainedResults[output] = stored
            retainedBytes += stored
            if size > sourceBytes { metadata += "；輸出比來源大，可降低品質或選擇其他格式" }
            return CompressionEngineResult(url: output, bytes: size, sourceBytes: sourceBytes, width: width,
                height: height, metadataStatus: metadata, frames: result["frames"] as? Int ?? 1,
                outputIdentity: identity, developedSource: isRAW ? stagedSource : nil,
                rawDecoder: isRAW ? rawDecoder : nil)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func runWebJob(id: String, view: WKWebView, options: [String: Any], credential: String,
                           preview: Bool, cancellation: CancellationToken) async throws -> Any {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Any, Error>) in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    completion.resume(throwing: CancellationError())
                    return
                }
                // WebKit completion may arrive after cancellation or never arrive after a crash.
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(preview ? 280 : 790)) }
                    catch { return }
                    guard let self else { return }
                    self.interruptWebJob(id, error: self.failure("壓縮引擎未在期限內回應。"))
                }
                webJobs[id] = WebJob(completion: completion, timeout: timeout)
                view.callAsyncJavaScript("return await window.compressionEngine.perform(options, credential);",
                    arguments: ["options": options, "credential": credential], in: nil, in: .page) { [weak self] result in
                    self?.finishWebJob(id, result: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.interruptWebJob(id, error: CancellationError()) }
        }
    }

    private func finishWebJob(_ id: String, result: Result<Any, Error>) {
        guard let job = webJobs.removeValue(forKey: id) else { return }
        job.timeout.cancel()
        job.completion.resume(with: result)
    }

    private func interruptWebJob(_ id: String, error: Error) {
        guard webJobs[id] != nil else { return }
        server?.unregister(id)
        webView?.callAsyncJavaScript("window.compressionEngine?.cancel(id); return null;",
                                    arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
        finishWebJob(id, result: .failure(error))
    }

    func cancelAll() {
        cancellations.values.forEach { $0.cancel() }
        webView?.evaluateJavaScript("window.compressionEngine?.cancelAll()")
        for id in Array(webJobs.keys) { finishWebJob(id, result: .failure(CancellationError())) }
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
        guard webView === self.webView else { return }
        isReady = false; loaded = false
        let message = "壓縮引擎已中止；清空後重新開啟程式可再試。"
        error = message
        server?.stop()
        for id in Array(webJobs.keys) { finishWebJob(id, result: .failure(failure(message))) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame == true, let server,
              action.request.url?.absoluteString == server.origin + "/engine.html" else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
