import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import TimezoneCore

@main
struct PhotoTimezoneApp: App {
    @NSApplicationDelegateAdaptor(PhotoAppDelegate.self) private var appDelegate
    @StateObject private var model = PhotoViewModel()

    var body: some Scene {
        Window("相片時區修改器", id: "main") {
            PhotoMainView(model: model)
                .background(WindowCloseGuard(model: model))
                .onAppear { appDelegate.connect(model) }
                .onOpenURL { model.addInputs([$0]) }
                .frame(minWidth: 1100, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("加入相片或資料夾…", action: model.chooseInputs)
                    .keyboardShortcut("o")
                    .disabled(model.isRunning)
            }
            CommandMenu("相片") {
                Button("掃描預覽", action: model.inspect)
                    .keyboardShortcut("r")
                    .disabled(!model.canInspect)
                Button("寫入時區…", action: model.requestWrite)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canWrite)
                Button("完成目前相片後取消", action: model.cancel)
                    .disabled(!model.isRunning || model.isCancelling)
                Divider()
                Button("從原始備份還原…", action: model.requestRestore)
                    .disabled(!model.canRestore)
                Button("匯出記錄…", action: model.exportLog)
                    .disabled(model.isRunning || model.summary?.logURL == nil)
            }
            CommandMenu("資訊") {
                Button("版本與診斷") { model.activePage = .diagnostics }
            }
        }
    }
}

enum AppPage: String, CaseIterable {
    case photos = "相片處理", diagnostics = "版本與診斷"
}

enum ProcessingScope: String, CaseIterable {
    case all = "全部預覽", filtered = "篩選結果", selected = "手動選取"
}

@MainActor
final class PhotoViewModel: ObservableObject {
    @Published private(set) var inputs: [URL] = []
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var recursive = true
    @Published private(set) var offset = UTCOffset(minutes: 480)
    @Published private(set) var mode: WriteMode = .fillMissing
    @Published private(set) var offsetTargets: OffsetTargets = WriteOptions.appDefault.targets
    @Published private(set) var sonyCompatibility = WriteOptions.appDefault.sonyCompatibility
    @Published private(set) var replaceOriginals = false
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var outputDirectory: URL?
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var phase = "加入相片，開始檢查時區"
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var progressSucceeded = 0
    @Published private(set) var progressFailed = 0
    @Published private(set) var progressSkipped = 0
    @Published private(set) var summary: JobSummary?
    @Published private(set) var reportTitle = "處理報告"
    @Published var selection: Set<PhotoItem.ID> = []
    @Published var query = "" { didSet { if query != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var filter: PhotoFilter = .all { didSet { if filter != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var cameraFilter = "" { didSet { if cameraFilter != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var sort: PhotoSort = .filename { didSet { if sort != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var scope: ProcessingScope = .all
    @Published var activePage: AppPage = .photos
    @Published var showingOffsetChooser = false
    @Published private(set) var filteredItems: [PhotoItem] = []
    @Published private(set) var pageItems: [PhotoItem] = []
    @Published private(set) var cameras: [(name: String, count: Int)] = []
    @Published private(set) var pageIndex = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var missingOffsetCount = 0
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var activeScopeCount = 0
    @Published var notice: PhotoNotice?
    @Published var dropTargeted = false

    init() {
        notificationsEnabled = UserDefaults.standard.bool(forKey: "PhotoTimezoneCompletionNotifications")
    }

    func setNotificationsEnabled(_ value: Bool) {
        guard value else {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "PhotoTimezoneCompletionNotifications")
            return
        }
        Task { @MainActor in
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = granted
                UserDefaults.standard.set(granted, forKey: "PhotoTimezoneCompletionNotifications")
                if !granted {
                    notice = .error("無法開啟完成通知", "系統未授權通知；仍可在 App 的進度與報告查看結果。")
                }
            } catch {
                notificationsEnabled = false
                notice = .error("無法開啟完成通知", error.localizedDescription)
            }
        }
    }

    private func postNotification(title: String, body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private struct ScanSignature: Equatable {
        let paths: [String]
        let recursive: Bool
    }

    private var previewSignature: ScanSignature?
    private var previewFileURLs: [URL] = []
    private var itemIndices: [UUID: Int] = [:]
    private var cancellation: CancellationToken?
    private var activeRunID: UUID?
    private var jobTask: Task<Void, Never>?
    private var catalogueTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var catalogueNeedsPageReset = false
    private var importTask: Task<Void, Never>?
    // Core events may arrive much faster than the UI can render. Only publish
    // an immutable snapshot at the display cadence, never once per photo.
    private var bufferedItems: [PhotoItem] = []
    private var bufferDirty = false
    private var pendingPhase: String?
    private var pendingCompleted: Int?
    private var pendingTotal: Int?
    private var bufferedSucceeded = 0
    private var bufferedFailed = 0
    private var bufferedSkipped = 0
    private var copySourceRootsForRetry: [URL]?

    private var currentSignature: ScanSignature {
        ScanSignature(paths: inputs.map(\.path).sorted(), recursive: recursive)
    }

    var canInspect: Bool { !isRunning && !inputs.isEmpty }
    var previewIsCurrent: Bool { previewSignature == currentSignature }
    var canWrite: Bool {
        canInspect && previewIsCurrent && scopedItems.contains { $0.status == .ready }
    }
    var canRestore: Bool { canInspect && previewIsCurrent && !scopedItems.isEmpty }
    var selectedItem: PhotoItem? { items.first { selection.contains($0.id) } }
    var pageCount: Int { max(1, (filteredItems.count + PhotoCatalogue.pageSize - 1) / PhotoCatalogue.pageSize) }
    var scopedItems: [PhotoItem] {
        switch scope {
        case .all: return items
        case .filtered: return filteredItems
        case .selected: return PhotoCatalogue.selected(items, ids: selection)
        }
    }
    var retryCount: Int { items.filter { PhotoFilter.unfinished.matches($0) }.count }
    var processingCount: Int { isRunning ? activeScopeCount : scopedItems.count }
    var estimateText: String {
        let elapsed = Int(elapsedSeconds)
        let time = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        guard completed >= 10, total > completed, elapsedSeconds >= 2 else { return "已用 \(time)" }
        let remaining = Int(elapsedSeconds / Double(completed) * Double(total - completed))
        return "已用 \(time) · 約剩 \(max(1, (remaining + 59) / 60)) 分鐘"
    }

    func setPage(_ index: Int) {
        pageIndex = min(max(index, 0), pageCount - 1)
        pageItems = PhotoCatalogue.page(filteredItems, index: pageIndex)
    }

    func selectFiltered() { refreshCatalogue(); selection = Set(filteredItems.map(\.id)); scope = .selected }

    func showFailures() {
        filter = .failed
        if let first = items.first(where: { $0.status == .failed }) { selection = [first.id] }
    }

    func retryUnfinished() {
        guard !isRunning else { return }
        let urls = items.filter { PhotoFilter.unfinished.matches($0) }.map(\.url)
        guard !urls.isEmpty else { return }
        copySourceRootsForRetry = copySourceRootsForRetry ?? inputs
        inputs = urls
        query = ""; filter = .all; cameraFilter = ""; scope = .all
        invalidatePreview()
        inspect()
    }

    private func scheduleCatalogue(resetPage: Bool = false) {
        catalogueNeedsPageReset = catalogueNeedsPageReset || resetPage
        guard catalogueTask == nil else { return }
        catalogueTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshCatalogue()
        }
    }

    private func refreshCatalogue() {
        catalogueTask?.cancel(); catalogueTask = nil
        if bufferDirty {
            items = bufferedItems
            bufferDirty = false
        }
        if let pendingPhase, !isCancelling { phase = pendingPhase }
        if let pendingCompleted { completed = pendingCompleted }
        if let pendingTotal { total = pendingTotal; activeScopeCount = pendingTotal }
        if progressSucceeded != bufferedSucceeded { progressSucceeded = bufferedSucceeded }
        if progressFailed != bufferedFailed { progressFailed = bufferedFailed }
        if progressSkipped != bufferedSkipped { progressSkipped = bufferedSkipped }
        pendingPhase = nil; pendingCompleted = nil; pendingTotal = nil
        filteredItems = PhotoCatalogue.filtered(items, query: query, filter: filter,
                                                camera: cameraFilter.isEmpty ? nil : cameraFilter, sort: sort)
        let counts = Dictionary(grouping: items.compactMap { $0.metadata?.camera }, by: { $0 }).mapValues(\.count)
        cameras = counts.map { (name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
        missingOffsetCount = items.filter { $0.metadata?.missingCaptureOffset == true }.count
        totalBytes = items.reduce(0) { $0 + ($1.metadata?.fileSize ?? 0) }
        setPage(catalogueNeedsPageReset ? 0 : pageIndex)
        catalogueNeedsPageReset = false
    }

    func setRecursive(_ value: Bool) {
        guard !isRunning, recursive != value else { return }
        recursive = value
        invalidatePreview()
        if canInspect { inspect() }
    }

    func setOffset(_ value: UTCOffset) {
        guard !isRunning, offset != value else { return }
        offset = value
    }

    func setMode(_ value: WriteMode) {
        guard !isRunning, mode != value else { return }
        mode = value
    }

    func setOffsetTargets(_ value: OffsetTargets) {
        guard !isRunning else { return }
        offsetTargets = value
    }

    func setSonyCompatibility(_ value: Bool) {
        guard !isRunning else { return }
        sonyCompatibility = value
    }

    func setReplaceOriginals(_ value: Bool) {
        guard !isRunning else { return }
        replaceOriginals = value
    }

    func chooseOutputDirectory(confirmAfterSelection: Bool = false) {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "選擇副本輸出資料夾"
        panel.message = "請選獨立於來源的資料夾；不會覆蓋目的地已有的同名檔案。"
        panel.prompt = "使用此資料夾"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let selected = panel.url, let self else { return }
                do {
                    try CopyDestination.validate(selected, roots: self.copySourceRootsForRetry ?? self.inputs)
                    self.outputDirectory = selected.standardizedFileURL
                    if confirmAfterSelection { self.requestWrite() }
                } catch {
                    self.notice = .error("無法使用這個輸出資料夾", error.localizedDescription)
                }
            }
        }
    }

    func addInputs(_ urls: [URL]) {
        var known = Set(inputs.map(\.path))
        let additions = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter {
            known.insert($0.path).inserted
        }
        guard !additions.isEmpty else { return }
        guard !isRunning else { notice = .busyInput; return }
        copySourceRootsForRetry = nil
        inputs.append(contentsOf: additions)
        scope = .all
        query = ""; filter = .all; cameraFilter = ""
        invalidatePreview()
        // Import is read-only: automatically reveal metadata, never write.
        // Coalesce multiple open-URL events from one Finder drag before starting.
        importTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.inspect()
        }
    }

    func removeInput(_ url: URL) {
        guard !isRunning else { return }
        copySourceRootsForRetry = nil
        inputs.removeAll { $0 == url }
        invalidatePreview()
    }

    func clearInputs() {
        guard !isRunning else { return }
        copySourceRootsForRetry = nil
        inputs.removeAll()
        invalidatePreview()
    }

    private func invalidatePreview() {
        importTask?.cancel(); importTask = nil
        previewSignature = nil
        previewFileURLs = []
        items = []
        bufferedItems = []; bufferDirty = false
        itemIndices = [:]
        selection = []
        bufferedSucceeded = 0
        bufferedFailed = 0
        bufferedSkipped = 0
        refreshCatalogue()
        // Keep the last report available for export until the next job starts.
        phase = inputs.isEmpty ? "加入相片，開始檢查時區" : "來源已更新，請先掃描預覽"
        completed = 0
        total = 0
        progressSucceeded = 0
        progressFailed = 0
        progressSkipped = 0
    }

    func chooseInputs() {
        guard !isRunning else { notice = .busyInput; return }
        // Resolve the document window before constructing a panel: keyWindow
        // can refer to a panel instead of the SwiftUI window during transitions.
        let sourceWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" }
            ?? NSApp.mainWindow ?? NSApp.keyWindow
        let panel = NSOpenPanel()
        panel.title = "加入相片或資料夾"
        panel.message = "可同時選取多張相片與多個資料夾。加入後自動讀取資訊，不會修改相片。"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor in
                sourceWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                if response == .OK { self?.addInputs(panel.urls) }
            }
        }
        // As a sheet, this mixed file/directory chooser can leave "Add"
        // disabled despite a selected file on current macOS. A standalone
        // panel validates the same selection correctly.
        panel.begin(completionHandler: completion)
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning else { notice = .busyInput; return true }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task { @MainActor [weak self] in
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL {
                            continuation.resume(returning: url)
                        } else if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else if let string = item as? String {
                            continuation.resume(returning: URL(string: string))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard let self else { return }
            if self.isRunning {
                self.notice = .busyInput
            } else if urls.isEmpty {
                self.notice = .error("無法讀取拖入的項目", "請拖入本機相片或資料夾，或使用「加入項目」選取。")
            } else {
                self.addInputs(urls)
            }
        }
        return true
    }

    func inspect() {
        guard canInspect else { return }
        start(.inspect)
    }

    func requestWrite() {
        refreshCatalogue()
        guard canWrite else { return }
        if !replaceOriginals && outputDirectory == nil {
            chooseOutputDirectory(confirmAfterSelection: true)
            return
        }
        if let outputDirectory, !replaceOriginals {
            do { try CopyDestination.validate(outputDirectory, roots: copySourceRootsForRetry ?? inputs) }
            catch { notice = .error("無法使用這個輸出資料夾", error.localizedDescription); return }
        }
        var placement = replaceOriginals ? "替換來源照片；每張先保留可復原備份" : "輸出副本至：\(outputDirectory?.path ?? "未選擇")；來源照片不更動"
        placement += "\n欄位：\(offsetTargets == .captureOnly ? "只寫 EXIF 拍攝時區 OffsetTimeOriginal" : "寫入三個 EXIF OffsetTime 欄位")。"
        if sonyCompatibility {
            placement += "\nSony 相容模式已開啟：允許已驗證的內部位置重排，但無法保證 MakerNotes 私有位元組完全不變。"
        }
        notice = .writeConfirmation(scopedItems.count, offset.value, mode == .replaceAll, placement)
    }

    func confirmReplace() {
        guard canWrite else { return }
        let options = WriteOptions(targets: offsetTargets, sonyCompatibility: sonyCompatibility)
        if replaceOriginals {
            start(.write(offset: offset, mode: mode, options: options))
        } else if let outputDirectory {
            start(.writeCopy(offset: offset, mode: mode, destination: outputDirectory,
                             sourceRoots: copySourceRootsForRetry ?? inputs, options: options))
        }
    }

    func requestRestore() {
        refreshCatalogue()
        guard canRestore else { return }
        notice = .restore
    }

    func confirmRestore() {
        guard canRestore else { return }
        start(.restore)
    }

    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        cancellation?.cancel()
        // Never cancel the task or terminate ExifTool; the engine finishes the current photo.
        phase = "正在完成目前相片，之後取消剩餘工作…"
    }

    func requestClose() {
        notice = .busyClose
    }

    private func start(_ operation: JobOperation) {
        guard !isRunning, !inputs.isEmpty else { return }
        let engineURL: URL
        do {
            engineURL = try EngineResources.exiftoolURL()
        } catch {
            notice = .error("無法啟動相片處理工具", "找不到或無法使用 App 內附的 ExifTool。請確認 App 已完整安裝。\n\n\(error.localizedDescription)")
            return
        }

        let runID = UUID()
        let signature = currentSignature
        let jobInputs: [URL]
        let includeSubfolders: Bool
        switch operation {
        case .inspect:
            jobInputs = inputs
            includeSubfolders = recursive
        case .write, .writeCopy, .restore:
            guard previewIsCurrent, !previewFileURLs.isEmpty else { return }
            // Freeze the exact inspected files, including failed files for per-file reporting.
            // Never rescan the originally selected folders during a mutating operation.
            let inspectedPaths = Set(previewFileURLs.map(\.path))
            jobInputs = scopedItems.map(\.url).filter { inspectedPaths.contains($0.path) }
            guard !jobInputs.isEmpty else { return }
            includeSubfolders = false
        }
        let token = CancellationToken()
        activeRunID = runID
        cancellation = token
        previewSignature = nil
        previewFileURLs = []
        summary = nil
        items = []
        bufferedItems = []; bufferDirty = false
        pendingPhase = nil; pendingCompleted = nil; pendingTotal = nil
        itemIndices = [:]
        selection = []
        bufferedSucceeded = 0
        bufferedFailed = 0
        bufferedSkipped = 0
        refreshCatalogue()
        completed = 0
        total = 0
        progressSucceeded = 0
        progressFailed = 0
        progressSkipped = 0
        isCancelling = false
        isRunning = true
        activeScopeCount = jobInputs.count
        elapsedSeconds = 0
        let startedAt = Date()
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
        switch operation {
        case .inspect:
            reportTitle = "掃描報告"
            phase = "正在尋找相片並讀取 EXIF…"
        case .write:
            reportTitle = "替換原檔報告"
            phase = "正在準備替換原檔…"
        case .writeCopy:
            reportTitle = "副本輸出報告"
            phase = "正在準備輸出副本…"
        case .restore:
            reportTitle = "還原報告"
            phase = "正在尋找原始備份…"
        }
        if notificationsEnabled {
            switch operation {
            case .inspect: break
            default: postNotification(title: "相片時區處理開始", body: "正在處理 \(jobInputs.count) 張；請在 App 查看進度。")
            }
        }

        // A single ordered stream keeps discovery, row updates and the final report in order.
        let (events, continuation) = AsyncStream<JobEvent>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            await PhotoEngine(exiftoolURL: engineURL).run(
                inputs: jobInputs,
                recursive: includeSubfolders,
                operation: operation,
                cancellation: token,
                inspectedFilesOnly: { if case .inspect = operation { return false }; return true }(),
                onEvent: { continuation.yield($0) }
            )
            continuation.finish()
        }
        jobTask = Task { @MainActor [weak self] in
            for await event in events {
                self?.receive(event, runID: runID)
            }
            await worker.value
            self?.finish(operation, signature: signature, runID: runID, token: token)
        }
    }

    private func receive(_ event: JobEvent, runID: UUID) {
        guard activeRunID == runID else { return }
        switch event {
        case .discovered(let photos):
            // Upsert also tolerates engines that discover in batches.
            for photo in photos { upsert(photo) }
            pendingTotal = bufferedItems.count
        case .updated(let photo, let done, let count):
            upsert(photo)
            pendingCompleted = done
            pendingTotal = count
            switch photo.status {
            case .ready, .success: bufferedSucceeded += 1
            case .failed: bufferedFailed += 1
            case .skipped: bufferedSkipped += 1
            case .pending, .cancelled: break
            }
        case .phase(let text):
            if !isCancelling { pendingPhase = text; scheduleCatalogue() }
        case .finished(let result):
            refreshCatalogue()
            summary = result
            total = result.total
            bufferedSucceeded = result.succeeded
            bufferedFailed = result.failed
            bufferedSkipped = result.skipped
            progressSucceeded = result.succeeded
            progressFailed = result.failed
            progressSkipped = result.skipped
        }
    }

    private func upsert(_ photo: PhotoItem) {
        if let index = itemIndices[photo.id] {
            bufferedItems[index] = photo
        } else {
            itemIndices[photo.id] = bufferedItems.count
            bufferedItems.append(photo)
        }
        bufferDirty = true
        scheduleCatalogue()
    }

    private func finish(_ operation: JobOperation, signature: ScanSignature, runID: UUID, token: CancellationToken) {
        guard activeRunID == runID else { return }
        let wasCancelled = token.isCancelled || (summary?.cancelled ?? 0) > 0
        if case .inspect = operation, !wasCancelled, let summary,
           completed >= summary.total, signature == currentSignature, !items.isEmpty,
           !items.contains(where: { $0.status == .pending }) {
            previewSignature = signature
            // Directory rows can report discovery failures; they are not file inputs.
            previewFileURLs = items.filter { !$0.url.hasDirectoryPath }.map(\.url)
        }
        isRunning = false
        clockTask?.cancel(); clockTask = nil
        refreshCatalogue()
        if selection.isEmpty, let first = pageItems.first { selection = [first.id] }
        isCancelling = false
        cancellation = nil
        activeRunID = nil
        jobTask = nil
        if summary == nil {
            phase = "工作已結束，但未收到完整報告"
            notice = .error("未收到處理報告", "請重新掃描相片，確認狀態後再繼續。")
        } else if wasCancelled {
            phase = "已取消剩餘工作；已完成的相片不會回復"
        } else if previewIsCurrent {
            phase = "預覽完成，請確認時區與寫入方式"
        } else {
            phase = "工作完成；再次寫入前請重新掃描預覽"
        }
        if let summary {
            switch operation {
            case .inspect: break
            default:
                postNotification(title: "相片時區處理完成",
                                 body: "成功 \(summary.succeeded) 張、失敗 \(summary.failed) 張、略過 \(summary.skipped) 張。")
            }
        }
    }

    func exportLog() {
        guard !isRunning, let source = summary?.logURL else { return }
        let panel = NSSavePanel()
        panel.title = "匯出處理記錄"
        panel.prompt = "匯出"
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: source.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    guard source.standardizedFileURL != destination.standardizedFileURL else { return }
                    // Atomic copying preserves an existing destination if writing fails.
                    try Data(contentsOf: source).write(to: destination, options: .atomic)
                } catch {
                    self?.notice = .error("無法匯出記錄", error.localizedDescription)
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

enum PhotoNotice: Identifiable {
    case writeConfirmation(Int, String, Bool, String)
    case restore
    case busyInput
    case busyClose
    case error(String, String)

    var id: String {
        switch self {
        case .writeConfirmation: return "writeConfirmation"
        case .restore: return "restore"
        case .busyInput: return "busyInput"
        case .busyClose: return "busyClose"
        case .error(let title, let message): return title + message
        }
    }
}

private struct PhotoMainView: View {
    @ObservedObject var model: PhotoViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.activePage == .photos {
                HStack(alignment: .top, spacing: 0) {
                    settings
                        .frame(width: 290)
                    Divider()
                    workspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                DiagnosticsView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            activityBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.07))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.dropTargeted, perform: model.acceptDrop)
        .overlay {
            if model.showingOffsetChooser {
                Color.black.opacity(0.7).ignoresSafeArea()
                    .accessibilityHidden(true)
                OffsetChooserView(selected: model.offset, onConfirm: { chosen in
                    model.setOffset(chosen)
                    model.showingOffsetChooser = false
                }, onCancel: { model.showingOffsetChooser = false })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(item: $model.notice, content: alert)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: AppArtwork.icon)
                .resizable().interpolation(.high)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("相片時區修改器").font(.title2.bold())
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.4.1")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Text("拖入先看資訊，確認後才寫入。原格式與拍攝時間不變。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Picker("頁面", selection: $model.activePage) {
                ForEach(AppPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 245)
            .accessibilityIdentifier("mainPagePicker")
            if model.activePage == .photos {
                Button(action: model.chooseInputs) {
                    Label("加入項目…", systemImage: "plus")
                }
                .disabled(model.isRunning)
                .accessibilityIdentifier("addInputsButton")
                Button(action: model.inspect) {
                    Label("重新掃描", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canInspect)
                .accessibilityIdentifier("inspectButton")
                .help("讀取相片資訊；掃描不會修改檔案。")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var settings: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sources
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("02", "設定固定時區")
                    Button {
                        model.showingOffsetChooser = true
                    } label: {
                        HStack {
                            Label(model.offset.label, systemImage: "globe.asia.australia")
                                .font(.body.monospacedDigit().weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("選擇固定 UTC 時區偏移，現在為 \(model.offset.label)")
                    .accessibilityIdentifier("chooseOffsetButton")
                    .disabled(model.isRunning)
                    Text(OffsetGuide.examples(for: model.offset))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("選擇拍攝當時的固定 UTC 偏移，包含半小時與 15 分鐘選項。此設定不是城市時區，不會自動套用日光節約時間（夏令時間）。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("03", "選擇寫入方式")
                    Picker("寫入欄位", selection: Binding(get: { model.offsetTargets }, set: model.setOffsetTargets)) {
                        Text("只寫拍攝時區（建議）").tag(OffsetTargets.captureOnly)
                        Text("三個時區欄位（進階）").tag(OffsetTargets.allThree)
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("offsetTargetsPicker")
                    Text("預設只補 EXIF OffsetTimeOriginal；DateTimeOriginal 的鐘點不加減。三個欄位各有不同用途，只有確認其時間都適用同一偏移時才選進階。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("寫入方式", selection: Binding(get: { model.mode }, set: model.setMode)) {
                        Text("只補上缺少的時區").tag(WriteMode.fillMissing)
                        Text("覆寫所選時區").tag(WriteMode.replaceAll)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(model.isRunning)
                    .accessibilityLabel("時區寫入方式")
                    .accessibilityIdentifier("writeModePicker")
                    Text(model.mode == .fillMissing
                         ? "保留所選欄位已有的時區，只補缺漏。"
                         : "所選時區欄位會改成指定偏移；拍攝時間本身不變。")
                        .font(.caption)
                        .foregroundStyle(model.mode == .replaceAll ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Sony 相容模式（預設開啟）", isOn: Binding(
                        get: { model.sonyCompatibility }, set: model.setSonyCompatibility
                    ))
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("sonyCompatibilityToggle")
                    Text("只在 Sony 候選副本中容許已知的內部位置重排；仍逐張核對主影像、相關預覽／縮圖和可讀欄位。MakerNotes 原始位元組可能變動，無法保證私有資料逐位元不變。關閉可使用嚴格模式；建議先選副本輸出測試。")
                        .font(.caption)
                        .foregroundStyle(model.sonyCompatibility ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 11) {
                    sectionHeading("04", "選擇輸出位置")
                    Toggle("替換來源資料夾中的原照片", isOn: Binding(
                        get: { model.replaceOriginals }, set: model.setReplaceOriginals
                    ))
                    .font(.callout)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("replaceOriginalsToggle")
                    if model.replaceOriginals {
                        Text("逐張先驗證成品、保存原檔備份，再替換相同路徑的 JPEG／ARW／TIFF；不轉檔。")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Button(model.outputDirectory == nil ? "選擇副本輸出資料夾…" : "變更副本輸出資料夾…") {
                            model.chooseOutputDirectory()
                        }
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("chooseOutputDirectoryButton")
                        if let destination = model.outputDirectory {
                            Text(destination.path).font(.caption2).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                        }
                        Text("預設保留來源，副本輸出到你選的獨立資料夾；保留來源資料夾結構，不覆蓋同名檔案。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.replaceOriginals ? "替換前保留備份" : "來源原檔保持不動", systemImage: "checkmark.shield.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.green)
                    Text(model.replaceOriginals
                         ? "首次替換保留 _original，再次替換另存上一版本；復原也保留當前版本。"
                         : "只在輸出資料夾建立副本；來源照片不會被修改。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading("05", "處理範圍")
                    Picker("處理範圍", selection: $model.scope) {
                        Text("全部").tag(ProcessingScope.all)
                        Text("篩選").tag(ProcessingScope.filtered)
                        Text("已選").tag(ProcessingScope.selected)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("processingScopePicker")
                    Text("此次處理：\(model.processingCount) 張 · \(model.scope.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("處理開始與完成時通知", isOn: Binding(
                        get: { model.notificationsEnabled }, set: model.setNotificationsEnabled
                    ))
                    .accessibilityIdentifier("completionNotificationsToggle")
                    Text("預設關閉；開啟時才請求 macOS 通知權限。進度與逐張結果仍可在 App 查看。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        Divider()
        actionPanel.padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: model.requestWrite) {
                Label("檢查並寫入 \(model.offset.label)", systemImage: "clock.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!model.canWrite).accessibilityIdentifier("writeButton")
            Text(model.inputs.isEmpty ? "先加入相片；不會自動寫入。" : (model.previewIsCurrent ? "按下後會再次確認。" : "請先完成掃描預覽。"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("從原始備份還原…", action: model.requestRestore)
                .buttonStyle(.link).disabled(!model.canRestore)
                .accessibilityIdentifier("restoreButton")
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("01", "加入相片與資料夾")
                Spacer(minLength: 0)
                if !model.inputs.isEmpty {
                    Button("清空", action: model.clearInputs)
                        .buttonStyle(.link).font(.caption)
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("clearInputsButton")
                }
            }
            if model.inputs.isEmpty {
                Button(action: model.chooseInputs) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.title2)
                        Text("拖入相片或資料夾").font(.callout.weight(.medium))
                        Text("或按一下選取多個項目").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(dash: [5])))
                .accessibilityIdentifier("chooseSourceArea")
            } else {
                Text("已加入 \(model.inputs.count) 個來源")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(model.inputs, id: \.absoluteString) { url in
                            HStack(spacing: 8) {
                                Image(systemName: url.hasDirectoryPath ? "folder.fill" : "photo")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                                Text(url.lastPathComponent)
                                    .font(.caption).lineLimit(1).truncationMode(.middle)
                                    .help(url.path)
                                Spacer(minLength: 0)
                                Button { model.removeInput(url) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .disabled(model.isRunning)
                                .accessibilityLabel("移除來源：\(url.lastPathComponent)")
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(height: min(CGFloat(model.inputs.count) * 29 + 12, 135))
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle("包含子資料夾", isOn: Binding(get: { model.recursive }, set: model.setRecursive))
                .font(.callout)
                .disabled(model.isRunning)
                .accessibilityIdentifier("recursiveToggle")
            Text("拖入後自動讀取照片與資訊，不會更動檔案。記憶卡相片建議先複製到電腦，再處理副本。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("相片預覽").font(.title3.weight(.semibold))
                Spacer()
                if !model.items.isEmpty {
                    Text("\(model.items.count) 張 · 缺拍攝時區 \(model.missingOffsetCount) · \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.items.isEmpty {
                emptyState
            } else {
                catalogueToolbar
                photoTable
                pageControls
            }
            if model.selectedItem != nil || model.summary != nil {
                ScrollView {
                    VStack(spacing: 14) {
                        if let item = model.selectedItem {
                            metadataDetails(item)
                        }
                        if let summary = model.summary {
                            report(summary)
                        }
                    }
                }
                .frame(maxHeight: model.summary == nil ? 255 : 335)
                .accessibilityIdentifier("detailsAndReportScrollArea")
            }
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: model.isRunning ? "doc.text.magnifyingglass" : "photo.stack")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.75))
                .accessibilityHidden(true)
            Text(model.isRunning ? "正在準備相片清單" : (model.inputs.isEmpty ? "讓每張相片，保留正確時區" : "來源已就緒，先看看相片資訊"))
                .font(.title3.weight(.semibold))
            Text(model.isRunning ? "正在自動讀取，沒有修改任何相片。" : "拖入相片 → 自動看照片與資訊 → 你決定要不要修改")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !model.isRunning {
                Button(model.inputs.isEmpty ? "選取相片或資料夾…" : "開始掃描預覽") {
                    if model.inputs.isEmpty { model.chooseInputs() } else { model.inspect() }
                }
                .controlSize(.large)
                .padding(.top, 4)
                .accessibilityIdentifier("emptyStateAction")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var catalogueToolbar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                TextField("搜尋檔名、相機、鏡頭、日期…", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("photoSearch")
                Picker("狀態", selection: $model.filter) {
                    ForEach(PhotoFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 180).accessibilityIdentifier("photoFilter")
            }
            HStack(spacing: 10) {
                Picker("相機", selection: $model.cameraFilter) {
                    Text("所有相機").tag("")
                    ForEach(model.cameras, id: \.name) { camera in
                        Text("\(camera.name)（\(camera.count)）").tag(camera.name)
                    }
                }
                .frame(maxWidth: 300).accessibilityIdentifier("cameraFilter")
                Picker("排序", selection: $model.sort) {
                    ForEach(PhotoSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 180)
                Spacer(minLength: 0)
                Button("選取篩選結果", action: model.selectFiltered)
                    .disabled(model.filteredItems.isEmpty || model.isRunning)
                    .accessibilityIdentifier("selectFilteredButton")
                Button("取消選取") { model.selection = [] }
                    .disabled(model.selection.isEmpty || model.isRunning)
            }
            .controlSize(.small)
            Text("單擊照片看資訊；只改部分照片時，請將左側處理範圍設為『手動選取』或『篩選結果』。")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pageControls: some View {
        HStack(spacing: 10) {
            Text("篩選 \(model.filteredItems.count) / \(model.items.count) 張 · 已選 \(model.selection.count) 張")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { model.setPage(model.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(model.pageIndex == 0).accessibilityLabel("上一頁")
            Text("\(model.pageIndex + 1) / \(model.pageCount) 頁").font(.caption.monospacedDigit())
            Button { model.setPage(model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.pageIndex + 1 >= model.pageCount).accessibilityLabel("下一頁")
        }
        .controlSize(.small)
        .help("每頁最多 200 張以保持順暢。Shift／Command 可複選；『選取篩選結果』會選取全部符合項目，不限本頁。")
    }

    private var photoTable: some View {
        Table(model.pageItems, selection: $model.selection) {
            TableColumn("相片") { item in
                HStack(spacing: 8) {
                    Image(systemName: "photo").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .help(item.url.path)
            }
            .width(min: 150, ideal: 220)
            TableColumn("相機") { item in
                Text(item.metadata?.camera ?? "讀取中").font(.caption).lineLimit(1)
                    .help(item.metadata?.camera ?? "")
            }
            .width(min: 85, ideal: 125, max: 160)
            TableColumn("原始拍攝時間") { item in
                Text(display(item.metadata?.dateTimeOriginal))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(item.metadata?.dateTimeOriginal == nil ? .secondary : .primary)
            }
            .width(min: 130, ideal: 145, max: 175)
            TableColumn("來源時區") { item in
                Text(display(item.metadata?.offsetOriginal))
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 68, ideal: 80, max: 100)
            TableColumn("狀態") { item in
                Label(item.status.uiTitle, systemImage: item.status.uiSymbol)
                    .font(.caption)
                    .foregroundStyle(item.status.uiColor)
                    .help(item.detail)
                    .accessibilityLabel("\(item.status.uiTitle)，\(item.detail)")
            }
            .width(min: 82, ideal: 95, max: 110)
        }
        .frame(minHeight: 155)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.15)))
        .accessibilityIdentifier("photoTable")
        .overlay {
            if model.filteredItems.isEmpty && !model.isRunning {
                Text("沒有符合篩選條件的相片").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func metadataDetails(_ item: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(item.url.lastPathComponent).font(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.metadata?.fileType ?? "格式待確認").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                PhotoThumbnail(url: item.url)
                    .frame(width: 140, height: 105)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.metadata?.camera ?? "未知相機").font(.headline)
                    if let serial = item.metadata?.cameraSerialNumber {
                        Text("相機序號：\(serial)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(item.metadata?.lensModel ?? "鏡頭資訊未記錄").font(.caption).foregroundStyle(.secondary)
                    Text("ISO \(item.metadata?.iso ?? "—")  ·  \(item.metadata?.exposureTime ?? "—") 秒  ·  f/\(item.metadata?.aperture ?? "—")  ·  \(item.metadata?.focalLength ?? "焦距未記錄")")
                        .font(.caption).textSelection(.enabled)
                    Text("\(item.metadata?.dimensions ?? "尺寸未記錄")  ·  \(ByteCountFormatter.string(fromByteCount: item.metadata?.fileSize ?? 0, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("拍攝：\(item.metadata?.dateTimeOriginal ?? "未記錄")")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("快速查看") { NSWorkspace.shared.open(item.url) }
                    .controlSize(.small).help("用系統預設程式開啟原檔；本 App 不會修改它。")
            }
            HStack(alignment: .top, spacing: 18) {
                metadataField("拍攝時區", tag: "OffsetTimeOriginal", value: item.metadata?.offsetOriginal)
                metadataField("數位化時區", tag: "OffsetTimeDigitized", value: item.metadata?.offsetDigitized)
                metadataField("修改時區", tag: "OffsetTime", value: item.metadata?.offsetTime)
            }
            if let output = item.outputURL, let outputMetadata = item.outputMetadata {
                Divider()
                Text("輸出副本的時區 · 來源保持不變")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
                HStack(alignment: .top, spacing: 18) {
                    metadataField("拍攝時區", tag: "OffsetTimeOriginal", value: outputMetadata.offsetOriginal)
                    metadataField("數位化時區", tag: "OffsetTimeDigitized", value: outputMetadata.offsetDigitized)
                    metadataField("修改時區", tag: "OffsetTime", value: outputMetadata.offsetTime)
                }
                Text(output.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(output.path).textSelection(.enabled)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text(item.url.path).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).help(item.url.path).textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("metadataDetails")
        .id(item.id)
    }

    private func metadataField(_ title: String, tag: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(display(value)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(tag).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func report(_ summary: JobSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.reportTitle).font(.callout.weight(.semibold))
                Spacer()
                if model.retryCount > 0 {
                    Button("重新檢查失敗／取消 \(model.retryCount) 張", action: model.retryUnfinished)
                        .disabled(model.isRunning).controlSize(.small)
                }
                Button(action: model.exportLog) {
                    Label("匯出記錄…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .disabled(model.isRunning || summary.logURL == nil)
                .accessibilityIdentifier("exportLogButton")
            }
            HStack(spacing: 0) {
                reportCount("總計", value: summary.total, color: .primary)
                reportCount("完成", value: summary.succeeded, color: .green)
                reportCount("略過", value: summary.skipped, color: .secondary)
                reportCount("失敗", value: summary.failed, color: summary.failed > 0 ? .red : .secondary)
                reportCount("取消", value: summary.cancelled, color: .secondary)
            }
            let failures = model.items.filter { $0.status == .failed }
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("失敗原因", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout.weight(.semibold))
                        Spacer()
                        Button("顯示全部失敗項目", action: model.showFailures)
                            .buttonStyle(.link).controlSize(.small)
                    }
                    ForEach(Array(failures.prefix(8))) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent).font(.caption.weight(.semibold))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if failures.count > 8 {
                        Text("另有 \(failures.count - 8) 張；按「顯示全部失敗項目」逐張查看。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("重試會先重新讀取失敗／取消的照片；確認資訊後再按寫入。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("failureDetails")
            }
            if !summary.message.isEmpty {
                Text(summary.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("fullJobSummaryMessage")
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("jobReport")
    }

    private func reportCount(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value) 張")
    }

    private var activityBar: some View {
        HStack(spacing: 16) {
            if model.isRunning {
                ProgressView().controlSize(.small).accessibilityLabel("正在處理相片")
            } else {
                Image(systemName: model.previewIsCurrent ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(model.previewIsCurrent ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.phase).font(.callout).lineLimit(2)
                    Spacer(minLength: 8)
                    if model.isRunning && model.total > 0 {
                        Text(model.estimateText).font(.caption).foregroundStyle(.secondary)
                        Text("\(model.completed) / \(model.total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if model.isRunning && model.total > 0 {
                    ProgressView(value: Double(min(model.completed, model.total)), total: Double(max(model.total, 1)))
                        .accessibilityLabel("處理進度")
                        .accessibilityValue("已處理 \(model.completed) 張，共 \(model.total) 張")
                    HStack(spacing: 12) {
                        Text("\(Int(Double(model.completed) / Double(model.total) * 100))%")
                        Text("成功 \(model.progressSucceeded)")
                        if model.progressSkipped > 0 { Text("略過 \(model.progressSkipped)") }
                        if model.progressFailed > 0 {
                            Text("失敗 \(model.progressFailed)").foregroundStyle(.red)
                        }
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if model.isRunning {
                Button(model.isCancelling ? "正在安全停止…" : "取消剩餘工作", action: model.cancel)
                    .disabled(model.isCancelling)
                    .help("完成目前相片後取消；不會強制中止 ExifTool。")
                    .accessibilityIdentifier("cancelJobButton")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(minHeight: 62)
        .background(.bar)
        .accessibilityIdentifier("activityBar")
    }

    private func sectionHeading(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.callout.weight(.semibold))
        }
    }

    private func display(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未填寫" }
        return value
    }

    private func alert(_ notice: PhotoNotice) -> Alert {
        switch notice {
        case .writeConfirmation(let count, let offset, let replace, let placement):
            return Alert(
                title: Text("確認處理 \(count) 張相片？"),
                message: Text("範圍：\(model.scope.rawValue)\n目標：UTC\(offset)\n方式：\(replace ? "覆寫所選時區（包含既有值）" : "只補缺漏，保留既有時區")\n位置：\(placement)\n\n拍攝時間數值不加減，也不轉換 JPEG／ARW／TIFF 格式；寫入 EXIF 時檔案內部可能重排，成品驗證後才提交。失敗檔案會個別列出，不會算入成功數量。\n\n請確認這批照片拍攝時使用相同偏移，並留足磁碟空間及獨立備份。"),
                primaryButton: .default(Text("確認寫入"), action: model.confirmReplace),
                secondaryButton: .cancel(Text("返回檢查"))
            )
        case .restore:
            return Alert(
                title: Text("從最早保留的原始備份還原？"),
                message: Text("範圍：\(model.scope.rawValue)，共 \(model.scopedItems.count) 張。將以第一次寫入時保留、最早的 _original 備份取代目前檔案，並非只復原上一次操作。\n\n還原前，目前版本會另存為 .before-restore-UUID.backup；_original 不會消耗。若原檔已遺失，會重建原檔並保留備份。沒有備份的相片將略過。"),
                primaryButton: .destructive(Text("還原原始備份"), action: model.confirmRestore),
                secondaryButton: .cancel(Text("取消"))
            )
        case .busyInput:
            return Alert(title: Text("請等待目前工作完成"), message: Text("正在處理相片，本次拖入或開啟的項目未加入。請在工作完成或取消後重新加入。"), dismissButton: .default(Text("知道了")))
        case .busyClose:
            return Alert(
                title: Text("相片仍在處理中"),
                message: Text("為確保檔案完整，目前無法關閉視窗或結束 App。可以繼續等待，或完成目前相片後取消剩餘工作。工作停止後，請再次關閉視窗。"),
                primaryButton: .default(Text("完成目前相片後取消"), action: model.cancel),
                secondaryButton: .cancel(Text("繼續等待"))
            )
        case .error(let title, let message):
            return Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("好")))
        }
    }
}

private extension PhotoStatus {
    var uiTitle: String {
        switch self {
        case .pending: return "等待中"
        case .ready: return "可處理"
        case .skipped: return "已略過"
        case .success: return "已完成"
        case .failed: return "失敗"
        case .cancelled: return "已取消"
        }
    }

    var uiSymbol: String {
        switch self {
        case .pending: return "clock"
        case .ready: return "checkmark.circle"
        case .skipped: return "minus.circle"
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    var uiColor: Color {
        switch self {
        case .pending, .skipped, .cancelled: return .secondary
        case .ready: return .accentColor
        case .success: return .green
        case .failed: return .red
        }
    }
}

@MainActor
final class PhotoAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: PhotoViewModel?
    private var pendingURLs: [URL] = []

    func connect(_ model: PhotoViewModel) {
        self.model = model
        if !pendingURLs.isEmpty {
            model.addInputs(pendingURLs)
            pendingURLs = []
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.addInputs(urls) } else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRunning else { return .terminateNow }
        model.requestClose()
        sender.activate(ignoringOtherApps: true)
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Intercepts only close requests and forwards SwiftUI's existing window-delegate behavior.
private struct WindowCloseGuard: NSViewRepresentable {
    let model: PhotoViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.onAttach = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
        context.coordinator.attach(to: nsView.window)
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var model: PhotoViewModel?
        private weak var originalDelegate: NSWindowDelegate?
        private weak var attachedWindow: NSWindow?

        init(model: PhotoViewModel) { self.model = model }

        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            if let attachedWindow, attachedWindow !== window, attachedWindow.delegate === self {
                attachedWindow.delegate = originalDelegate
            }
            originalDelegate = window.delegate
            attachedWindow = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let model, model.isRunning {
                model.requestClose()
                return false
            }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}

private final class WindowAttachmentView: NSView {
    var onAttach: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onAttach?(window)
    }
}
