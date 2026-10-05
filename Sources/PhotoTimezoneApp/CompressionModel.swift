import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import TimezoneCore

enum CompressionFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", png = "PNG", webp = "WebP", avif = "AVIF", heif = "HEIF", jxl = "JPEG XL"
    var id: String { rawValue }
    var mime: String {
        switch self { case .jpeg: return "image/jpeg"; case .png: return "image/png"
        case .webp: return "image/webp"; case .avif: return "image/avif"
        case .heif: return "image/heif"; case .jxl: return "image/jxl" }
    }
    var fileExtension: String {
        switch self { case .jpeg: return "jpg"; case .png: return "png"; case .webp: return "webp"
        case .avif: return "avif"; case .heif: return "heic"; case .jxl: return "jxl" }
    }
    var preservesRGBProfile: Bool { self != .avif }
    var recommendedQuality: Double { self == .heif ? 70 : self == .jpeg || self == .jxl ? 86 : 82 }
    var hint: String {
        switch self {
        case .jpeg: return "一般 .jpg；原生 Jpegli 漸進式壓縮，macOS／Windows 均可開啟。品質 100 仍為有損，透明區域轉白底。"
        case .png: return "PNG 無損編碼與透明圖片；8 位元滑桿調整壓縮努力度，16 位元來源使用 macOS 原生編碼保留精度。"
        case .webp: return "網站圖片；保留透明通道。"
        case .avif: return "較小的照片檔案；編碼較慢，像素使用 sRGB。"
        case .heif: return "macOS 原生 HEVC 編碼；適合 Apple 裝置。"
        case .jxl: return "原生 libjxl 編碼；品質 100 保留支援的 8／16 位元整數 RGB 像素。無法保證無損的來源會停止輸出。高解析照片會自動降低並行數。"
        }
    }
}

enum CompressionState: String { case pending = "待處理", running = "壓縮中", success = "完成", failed = "失敗", cancelled = "已取消" }

struct CompressionItem: Identifiable {
    let id: UUID
    let source: URL
    var originalBytes: Int64
    let width: Int
    let height: Int
    var state: CompressionState = .pending
    var progress = 0.0
    var phase = "待處理"
    var result: CompressionEngineResult?
    var format: CompressionFormat?
    var quality: Int?
    var elapsed = 0.0
    var error: String?
    var webhookStatus: String?
    var outputName: String {
        guard let format else { return source.lastPathComponent }
        return source.deletingPathExtension().lastPathComponent + "." + format.fileExtension
    }
    var measuredSourceBytes: Int64 { result?.sourceBytes ?? originalBytes }
    var savings: Double? { result.flatMap { CompressionModel.savings(source: measuredSourceBytes, output: $0.bytes) } }
}

@MainActor
final class CompressionModel: ObservableObject {
    static let jpegEncoderPreferenceVersion = "jpegli-v2-calibrated"

    private let preferences: UserDefaults
    let host = CompressionHost()
    @Published var items: [CompressionItem] = []
    @Published var selection: UUID? { didSet { updatePreview() } }
    @Published var format: CompressionFormat { didSet {
        let defaults = preferences
        defaults.set(quality, forKey: "nativeCompressionQuality." + oldValue.fileExtension)
        quality = defaults.object(forKey: "nativeCompressionQuality." + format.fileExtension) as? Double ?? format.recommendedQuality
        defaults.set(format.rawValue, forKey: "nativeCompressionFormat")
        if isActive { prepareSelectedFormat() }
        updatePreview()
    } }
    @Published var quality: Double { didSet { preferences.set(quality, forKey: "nativeCompressionQuality"); preferences.set(quality, forKey: "nativeCompressionQuality." + format.fileExtension); updatePreview() } }
    @Published var parallelism: Int { didSet { preferences.set(parallelism, forKey: "nativeCompressionParallelism") } }
    @Published var recursive = false
    @Published var isRunning = false
    @Published var isCancelling = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var dropTargeted = false
    @Published var originalPreview: NSImage?
    @Published var compressedPreview: NSImage?
    @Published var estimate: Int64?
    @Published var previewNote = "選取圖片，查看完整壓縮結果與輸出大小"
    @Published var previewLoading = false
    @Published var previewIsActual = false
    @Published var showingComparison = false
    @Published var comparisonScale = 1.0
    @Published var showingWebhook = false
    @Published var showingEngineInfo = false
    @Published var webhookEnabled = false
    @Published var webhookURL: String
    @Published var webhookToken = ""
    @Published var webhookStatus = ""
    @Published var notice: String?
    @Published var outputDirectory: URL?
    private var subscriptions: Set<AnyCancellable> = []
    private var previewTask: Task<Void, Never>?
    private struct PreviewCache {
        let source: URL
        let identity: FileIdentity
        let format: CompressionFormat
        let quality: Int
        let result: CompressionEngineResult
        let elapsed: TimeInterval
    }
    private var previewCache: PreviewCache?
    private var exportTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private let webhook = CompressionWebhook()
    private var batchID = ""
    private var isActive = false
    @Published var exportStatus = ""

    init(defaults: UserDefaults = .standard) {
        preferences = defaults
        let initialFormat = CompressionFormat(rawValue: defaults.string(forKey: "nativeCompressionFormat") ?? "") ?? .jpeg
        format = initialFormat
        let savedQuality: Double? = defaults.object(forKey: "nativeCompressionQuality") == nil
            ? nil : defaults.double(forKey: "nativeCompressionQuality")
        let initialQuality = initialFormat == .jpeg ? Self.qualityForCurrentJPEGEncoder(
            savedQuality: savedQuality,
            encoderVersion: defaults.string(forKey: "nativeCompressionJPEGEncoder")
        ) : min(100, max(1, savedQuality ?? initialFormat.recommendedQuality))
        let chosenQuality = defaults.object(forKey: "nativeCompressionQuality." + initialFormat.fileExtension) as? Double ?? initialQuality
        quality = chosenQuality
        defaults.set(chosenQuality, forKey: "nativeCompressionQuality")
        defaults.set(chosenQuality, forKey: "nativeCompressionQuality." + initialFormat.fileExtension)
        defaults.set(Self.jpegEncoderPreferenceVersion, forKey: "nativeCompressionJPEGEncoder")
        let savedParallelism = defaults.integer(forKey: "nativeCompressionParallelism")
        parallelism = savedParallelism > 0 ? min(4, savedParallelism) : 2
        webhookURL = defaults.string(forKey: "nativeCompressionWebhookURL") ?? ""
        host.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    static func qualityForCurrentJPEGEncoder(savedQuality: Double?, encoderVersion: String?) -> Double {
        guard let savedQuality, savedQuality.isFinite, savedQuality > 0 else { return 86 }
        let clamped = min(100, max(1, savedQuality))
        // Real-photo calibration chooses 86 as the size/quality compromise.
        // Preserve existing Jpegli choices; migrate only the legacy MozJPEG default.
        if encoderVersion == nil || encoderVersion == "mozjpeg", abs(savedQuality - 82) < 0.001 {
            return 86
        }
        return clamped
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { prepareSelectedFormat(); updatePreview() }
        else {
            previewTask?.cancel()
            previewLoading = false
            originalPreview = nil; compressedPreview = nil
            if !isRunning { discardPreviewCache(); host.cancelAll(); host.releaseRuntime() }
        }
    }

    private func prepareSelectedFormat() {
        if !isRunning { host.releaseRuntime() }
    }

    static func pngEffort(_ quality: Double) -> Int { Int((pow(min(100, max(1, quality)) / 100, 2) * 6).rounded()) }
    nonisolated static func savings(source: Int64, output: Int64) -> Double? {
        guard source > 0, output >= 0 else { return nil }
        return 1 - Double(output) / Double(source)
    }

    var selected: CompressionItem? { items.first { $0.id == selection } }
    var comparisonOutput: URL? {
        guard let item = selected else { return nil }
        if let result = item.result, item.format == format, item.quality == Int(quality.rounded()) { return result.url }
        return matchingPreviewCache(for: item, format: format, quality: Int(quality.rounded()))?.result.url
    }
    var completed: [CompressionItem] { items.filter { $0.result != nil && $0.state == .success } }
    var doneCount: Int { items.filter { [.success, .failed, .cancelled].contains($0.state) }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.originalBytes } }
    var completedSourceBytes: Int64 { completed.reduce(0) { $0 + $1.measuredSourceBytes } }
    var batchSavings: Double? { Self.savings(source: completedSourceBytes, output: resultBytes) }
    var resultBytes: Int64 { completed.reduce(0) { $0 + ($1.result?.bytes ?? 0) } }
    var progress: Double { items.isEmpty ? 0 : items.reduce(0) { $0 + ($1.state == .running ? $1.progress / 100 : [.success, .failed, .cancelled].contains($1.state) ? 1 : 0) } / Double(items.count) }
    var canStart: Bool { (format != .heif || CompressionHost.supportsHEIF) && !items.isEmpty && !isRunning && !isImporting && !isExporting }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    func chooseInputs() {
        guard !isRunning, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "加入要壓縮的圖片或資料夾"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in if response == .OK { Task { @MainActor in self?.addInputs(panel.urls) } } }
    }

    func addInputs(_ urls: [URL]) {
        guard !isRunning, !isImporting else { return }
        isImporting = true
        let known = Set(items.map { $0.source.path })
        let recursive = recursive
        Task {
            let discovered = await Task.detached(priority: .userInitiated) {
                let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "avif", "heic", "heif", "gif", "tif", "tiff"]
                let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
                var paths = known
                var result: [CompressionItem] = []
                func append(_ url: URL) {
                    let source = url.standardizedFileURL
                    guard extensions.contains(source.pathExtension.lowercased()), paths.insert(source.path).inserted,
                          let values = try? source.resourceValues(forKeys: Set(keys + [.fileSizeKey])),
                          values.isRegularFile == true, values.isSymbolicLink != true else { return }
                    let size = Int64(values.fileSize ?? 0)
                    let properties = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                    var item = CompressionItem(id: UUID(), source: source, originalBytes: size,
                        width: properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                        height: properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
                    if size > 256 * 1024 * 1024 { item.state = .failed; item.error = "來源檔案超過 256 MiB 上限" }
                    result.append(item)
                }
                func walkFolder(_ url: URL) {
                    let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: options) {
                        for case let file as URL in enumerator {
                            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                            append(file)
                        }
                    }
                }
                for url in urls where url.isFileURL {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isDirectory == true, values?.isSymbolicLink != true { walkFolder(url) }
                    else { append(url) }
                }
                return result.sorted { $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending }
            }.value
            items.append(contentsOf: discovered)
            isImporting = false
            if selection == nil { selection = items.first?.id }
            if discovered.isEmpty { notice = "沒有加入新的支援影像。支援 JPEG、PNG、WebP、AVIF、HEIC／HEIF、GIF 與 TIFF。" }
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning, !isImporting else { return false }
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in supported {
                let url: URL? = await withCheckedContinuation { continuation in
                    if provider.canLoadObject(ofClass: NSURL.self) {
                        provider.loadObject(ofClass: NSURL.self) { value, _ in
                            continuation.resume(returning: (value as? NSURL).map { $0 as URL })
                        }
                    } else {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                        }
                    }
                }
                if let url { urls.append(url) }
            }
            addInputs(urls)
        }
        return true
    }

    func clear() {
        guard !isRunning, !isExporting, !isImporting else { return }
        previewTask?.cancel(); host.cancelAll()
        discardPreviewCache()
        let results = items.compactMap { $0.result?.url.deletingLastPathComponent() }
        exportStatus = ""; webhookStatus = ""
        items = []; selection = nil; originalPreview = nil; compressedPreview = nil; estimate = nil
        Task.detached { for url in results { try? FileManager.default.removeItem(at: url) } }
    }

    func removeSelected() {
        guard !isRunning, !isExporting, !isImporting, let item = selected else { return }
        previewTask?.cancel(); host.cancelAll()
        if previewCache?.source.path == item.source.path { discardPreviewCache() }
        if let directory = item.result?.url.deletingLastPathComponent() { Task.detached { try? FileManager.default.removeItem(at: directory) } }
        items.removeAll { $0.id == item.id }; selection = items.first?.id
    }

    func updatePreview() {
        previewTask?.cancel()
        if !isRunning && previewLoading { host.cancelAll() }
        guard isActive else { return }
        previewLoading = false; previewIsActual = false
        guard let item = selected else {
            discardPreviewCache()
            originalPreview = nil; compressedPreview = nil; estimate = nil
            return
        }
        let chosenFormat = format, chosenQuality = Int(quality.rounded())
        let cached = matchingPreviewCache(for: item, format: chosenFormat, quality: chosenQuality)
        if previewCache != nil && cached == nil { discardPreviewCache() }
        previewTask = Task {
            let original = await Task.detached { CompressionImages.thumbnail(item.source) }.value
            guard !Task.isCancelled else { return }
            originalPreview = original
            if let result = item.result, item.state == .success, item.format == chosenFormat, item.quality == chosenQuality {
                let actualPreview = await Task.detached { CompressionImages.thumbnail(result.url) }.value
                guard !Task.isCancelled else { return }
                compressedPreview = actualPreview
                previewIsActual = true
                estimate = result.bytes
                previewNote = compressedPreview == nil ? "此系統無法預覽輸出格式；檔案仍可儲存。" : "顯示實際壓縮結果"
                previewLoading = false
                return
            }
            if let cached {
                let actualPreview = await Task.detached {
                    CompressionImages.thumbnail(cached.result.url)
                }.value
                guard !Task.isCancelled else { return }
                compressedPreview = actualPreview
                previewIsActual = true
                estimate = cached.result.bytes
                previewNote = actualPreview == nil ? "此系統無法預覽輸出格式；檔案仍可儲存。" : "顯示完整影像輸出；開始批次時會重用此結果。"
                previewLoading = false
                return
            }
            compressedPreview = nil; estimate = nil
            guard !isRunning else { previewNote = "壓縮完成後顯示實際結果"; return }
            previewLoading = true; previewNote = "正在產生預覽…"
            var generated: CompressionEngineResult?
            var retained = false
            defer {
                if !retained, let generated {
                    let directory = generated.url.deletingLastPathComponent()
                    Task.detached { try? FileManager.default.removeItem(at: directory) }
                }
            }
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
                try Task.checkCancellation()
                let identity = try await Task.detached { try FileIdentity.read(item.source) }.value
                let started = Date()
                let result = try await host.perform(source: item.source, format: chosenFormat, quality: chosenQuality, preview: false)
                generated = result
                try Task.checkCancellation()
                try identity.verify(item.source)
                guard isActive, selection == item.id, format == chosenFormat,
                      Int(quality.rounded()) == chosenQuality else { return }
                let actualPreview = await Task.detached {
                    CompressionImages.thumbnail(result.url)
                }.value
                try Task.checkCancellation()
                previewCache = PreviewCache(source: item.source, identity: identity, format: chosenFormat,
                    quality: chosenQuality, result: result, elapsed: Date().timeIntervalSince(started))
                retained = true
                compressedPreview = actualPreview
                previewIsActual = true
                estimate = result.bytes
                previewNote = actualPreview == nil ? "此系統無法預覽輸出格式；完整輸出大小已取得。" : "顯示完整影像輸出；開始批次時會重用此結果。"
                previewLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                previewNote = "預覽無法完成：\(error.localizedDescription)"; previewLoading = false
            }
        }
    }

    func start() {
        guard canStart else { return }
        let config: CompressionWebhook.Configuration?
        do { config = webhookEnabled ? try CompressionWebhook.Configuration(url: webhookURL, token: webhookToken) : nil }
        catch { notice = error.localizedDescription; return }
        preferences.set(webhookURL, forKey: "nativeCompressionWebhookURL")
        previewTask?.cancel(); host.cancelAll()
        let chosenFormat = format, chosenQuality = Int(quality.rounded())
        let largestPixels = items.map { max(1, min(20000, $0.width)) * max(1, min(20000, $0.height)) }.max() ?? 1
        let concurrency = Self.concurrencyLimit(format: chosenFormat, requested: parallelism,
            pixelCount: largestPixels, physicalMemory: ProcessInfo.processInfo.physicalMemory)
        let reusablePreview = selected.flatMap { matchingPreviewCache(for: $0, format: chosenFormat, quality: chosenQuality) }
        if previewCache != nil && reusablePreview == nil { discardPreviewCache() }
        for index in items.indices {
            let reusesPreview = reusablePreview?.source.path == items[index].source.path
            if let result = items[index].result,
               !reusesPreview || result.url != reusablePreview?.result.url {
                try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
            }
            items[index].result = reusesPreview ? reusablePreview?.result : nil
            items[index].state = reusesPreview ? .success : .pending
            items[index].progress = reusesPreview ? 100 : 0
            items[index].phase = reusesPreview ? "完成" : "待處理"
            items[index].format = chosenFormat; items[index].quality = chosenQuality
            items[index].error = nil; items[index].webhookStatus = nil
            if reusesPreview { items[index].elapsed = reusablePreview?.elapsed ?? 0 }
        }
        // The batch now owns the preview file. Do not delete its temporary directory.
        previewCache = nil
        let ids = items.filter { $0.state == .pending }.map(\.id)
        webhookStatus = ""; exportStatus = "處理中，尚未儲存"
        isRunning = true; isCancelling = false; batchID = UUID().uuidString
        compressedPreview = nil; estimate = nil; previewLoading = false
        batchTask = Task {
            if let config, let reusablePreview,
               let index = items.firstIndex(where: { $0.result?.url == reusablePreview.result.url }) {
                items[index].webhookStatus = "傳送中"
                do {
                    try await webhook.send(item: items[index], configuration: config, batchID: batchID)
                    items[index].webhookStatus = "已傳送"
                } catch { items[index].webhookStatus = "傳送失敗：\(error.localizedDescription)" }
            }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(concurrency, ids.count) {
                    let id = ids[next]; next += 1
                    group.addTask { await self.process(id, format: chosenFormat, quality: chosenQuality, webhook: config) }
                }
                while await group.next() != nil {
                    if next < ids.count && !isCancelling {
                        let id = ids[next]; next += 1
                        group.addTask { await self.process(id, format: chosenFormat, quality: chosenQuality, webhook: config) }
                    }
                }
                if isCancelling { for index in items.indices where items[index].state == .pending { items[index].state = .cancelled } }
            }
            if let config, !isCancelling {
                do { try await webhook.summary(configuration: config, batchID: batchID, items: items); webhookStatus = "批次摘要已送出" }
                catch { webhookStatus = "摘要傳送失敗：\(error.localizedDescription)" }
            }
            isRunning = false; isCancelling = false
            exportStatus = completed.isEmpty ? "沒有可儲存的壓縮結果" : "壓縮完成，尚未儲存"
            batchTask = nil
            if !isActive { host.releaseRuntime() }
            updatePreview()
        }
    }

    static func concurrencyLimit(format: CompressionFormat, requested: Int,
                                 pixelCount: Int, physicalMemory: UInt64) -> Int {
        // Conservative 16-bit buffers and codec scratch space; this is not a process RSS cap.
        let bytesPerPixel = format == .jxl ? 48 : format == .avif ? 32 : 28
        let budget = min(512 * 1024 * 1024,
            max(128 * 1024 * 1024, Int(physicalMemory / 16)))
        return min(max(1, requested), max(1, budget / max(1, pixelCount * bytesPerPixel)))
    }

    private func matchingPreviewCache(for item: CompressionItem, format: CompressionFormat,
                                      quality: Int) -> PreviewCache? {
        guard let previewCache, previewCache.source.path == item.source.path,
              previewCache.format == format, previewCache.quality == quality,
              FileManager.default.fileExists(atPath: previewCache.result.url.path) else { return nil }
        do { try previewCache.identity.verify(item.source) } catch { return nil }
        return previewCache
    }

    private func discardPreviewCache() {
        guard let cache = previewCache else { return }
        previewCache = nil
        let directory = cache.result.url.deletingLastPathComponent()
        Task.detached { try? FileManager.default.removeItem(at: directory) }
    }

    private func process(_ id: UUID, format: CompressionFormat, quality: Int, webhook config: CompressionWebhook.Configuration?) async {
        guard let index = items.firstIndex(where: { $0.id == id }), !isCancelling else { return }
        let source = items[index].source, started = Date()
        items[index].state = .running
        do {
            let result = try await host.perform(source: source, format: format, quality: quality, preview: false) { [weak self] pct, phase in
                guard let self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[index].progress = pct; self.items[index].phase = Self.phaseLabel(phase)
            }
            if isCancelling { try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent()); throw CancellationError() }
            items[index].originalBytes = result.sourceBytes ?? items[index].originalBytes
            items[index].result = result; items[index].progress = 100; items[index].state = .success
            items[index].phase = "完成"; items[index].elapsed = Date().timeIntervalSince(started)
            if result.frames > 1 { items[index].error = "動畫來源僅輸出第一幀" }
            if selection == id { updatePreview() }
            if let config {
                items[index].webhookStatus = "傳送中"
                do { try await webhook.send(item: items[index], configuration: config, batchID: batchID); items[index].webhookStatus = "已傳送" }
                catch { items[index].webhookStatus = "傳送失敗：\(error.localizedDescription)" }
            }
        } catch {
            items[index].state = isCancelling ? .cancelled : .failed
            items[index].phase = items[index].state.rawValue
            items[index].error = isCancelling ? nil : error.localizedDescription
        }
    }

    static func phaseLabel(_ phase: String) -> String {
        if phase.contains("DECOD") { return "解碼中" }
        if phase.contains("ENCOD") { return "編碼中" }
        if phase.contains("INITIAL") { return "準備中" }
        if phase == "DONE" { return "驗證輸出" }
        return phase
    }

    func cancel() { guard isRunning else { return }; isCancelling = true; batchTask?.cancel(); host.cancelAll() }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in if response == .OK { Task { @MainActor in self?.outputDirectory = panel.url } } }
    }

    func saveSelected() {
        guard let item = selected, let result = item.result else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.outputName; panel.directoryURL = outputDirectory
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                guard self.safeDestination(url) else { return }
                self.export { try CompressionExports.saveFile(result.url, to: url) }
            }
        }
    }

    func saveAll() {
        guard !completed.isEmpty else { return }
        if let outputDirectory {
            let files = completed.map { ($0.result!.url, $0.outputName) }
            export { try CompressionExports.saveAll(files, in: outputDirectory) }
        } else {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in self?.outputDirectory = url; self?.saveAll() }
            }
        }
    }

    func saveZIP() {
        guard !completed.isEmpty else { return }
        let files = completed.map { ($0.result!.url, $0.outputName) }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "影像壓縮.zip"; panel.directoryURL = outputDirectory
        panel.begin { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            Task { @MainActor in
                guard let self, self.safeDestination(target) else { return }
                self.export { try CompressionExports.zip(files, to: target) }
            }
        }
    }

    func exportReport() {
        let header = "來源,狀態,格式,原始大小,輸出大小,中繼資料,Webhook,說明\n"
        func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let report = header + items.map { item in
            [item.source.path, item.state.rawValue, item.format?.rawValue ?? "", String(item.measuredSourceBytes),
             item.result.map { String($0.bytes) } ?? "", item.result?.metadataStatus ?? "", item.webhookStatus ?? "", item.error ?? ""].map(csv).joined(separator: ",")
        }.joined(separator: "\n")
        let panel = NSSavePanel(); panel.nameFieldStringValue = "影像壓縮結果.csv"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, self.safeDestination(url) else { return }
                self.export(successMessage: "已儲存 CSV 報告；圖片須另行儲存") { try Data(report.utf8).write(to: url, options: .atomic) }
            }
        }
    }

    private func export(successMessage: String = "已儲存輸出", _ operation: @escaping () throws -> Void) {
        guard !isExporting, !isRunning else { return }
        isExporting = true
        exportTask = Task {
            do { try await Task.detached(priority: .userInitiated) { try operation() }.value }
            catch { notice = error.localizedDescription; exportStatus = "儲存失敗，壓縮結果仍可重新儲存"; isExporting = false; return }
            exportStatus = successMessage
            isExporting = false
        }
    }

    private func safeDestination(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard !items.contains(where: { $0.source.resolvingSymlinksInPath().standardizedFileURL == resolved }) else {
            notice = "請使用另一個檔名，避免取代已匯入的來源圖片。"; return false
        }
        return true
    }

    func testWebhook() {
        Task {
            webhookStatus = "測試連線中…"
            do {
                let config = try CompressionWebhook.Configuration(url: webhookURL, token: webhookToken)
                try await webhook.test(configuration: config); webhookStatus = "連線成功"
                preferences.set(webhookURL, forKey: "nativeCompressionWebhookURL")
            } catch { webhookStatus = "連線失敗：\(error.localizedDescription)" }
        }
    }
}

enum CompressionExports {
    static func saveFile(_ source: URL, to target: URL) throws {
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: target, options: .atomic)
    }
    static func saveAll(_ files: [(URL, String)], in folder: URL) throws {
        for (source, name) in files {
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            let ext = URL(fileURLWithPath: name).pathExtension
            var index = 1
            while true {
                let target = folder.appendingPathComponent(index == 1 ? name : "\(base) (\(index)).\(ext)")
                do { try FileManager.default.copyItem(at: source, to: target); break }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { index += 1 }
            }
        }
    }
    static func zip(_ files: [(URL, String)], to target: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTimezoneZIP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let images = staging.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        try saveAll(files, in: images)
        let archive = staging.appendingPathComponent("output.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", images.path, archive.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try ChildProcessRegistry.shared.launch(process)
        defer { ChildProcessRegistry.shared.finished(process) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Compression", code: 1, userInfo: [NSLocalizedDescriptionKey: "ZIP 打包失敗。"]) }
        try saveFile(archive, to: target)
    }
}
