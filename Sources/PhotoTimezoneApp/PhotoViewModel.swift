import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import TimezoneCore

@MainActor
final class PhotoViewModel: ObservableObject {
    @Published private(set) var inputs: [URL] = []
    var items: [PhotoItem] { bufferedItems }
    @Published private(set) var catalogueUpdating = false
    @Published private(set) var recursive = true
    @Published private(set) var offset = UTCOffset(minutes: 480)
    @Published private(set) var mode: WriteMode = .fillMissing
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
    @Published var gpsEnabled = false
    @Published var gpsOverwrite = false
    @Published var gpsLatitudeInput = ""
    @Published var gpsLongitudeInput = ""
    @Published var gpsAltitudeInput = ""
    @Published var query = "" { didSet { if query != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var filter: PhotoFilter = .all { didSet { if filter != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var cameraFilter = "" { didSet { if cameraFilter != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var sort: PhotoSort = .filename { didSet { if sort != oldValue { scheduleCatalogue(resetPage: true) } } }
    @Published var scope: ProcessingScope = .all
    @Published var activePage: AppPage = .photos
    @Published var showingOffsetChooser = false
    @Published var showingRecovery = false
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
    private let catalogueIndex = CatalogueIndex()
    private var projectionTask: Task<Void, Never>?
    private var catalogueRevision: UInt64 = 0
    private var projectionRevision: UInt64 = .max
    private var catalogueGeneration: UInt64 = 0
    private var lastProjectionStarted: TimeInterval = -.infinity
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
        canInspect && !catalogueUpdating && previewIsCurrent &&
            !(gpsEnabled ? allInspectedPhotoItems : writableItems).isEmpty
    }
    private var allInspectedPhotoItems: [PhotoItem] {
        let paths = Set(previewFileURLs.map(\.path))
        return items.filter { paths.contains($0.url.path) && !$0.publicationUnconfirmed }
    }
    private var writableItems: [PhotoItem] {
        scopedItems.filter { $0.status == .ready && $0.sourceIdentity != nil && !$0.publicationUnconfirmed }
    }
    var canRestore: Bool { canInspect && !catalogueUpdating && previewIsCurrent && !scopedItems.isEmpty }
    var selectedItem: PhotoItem? { items.first { selection.contains($0.id) } }
    var canAddGPSToSelected: Bool {
        guard !isRunning, !catalogueUpdating, previewIsCurrent, selection.count == 1,
              let item = selectedItem, item.status == .ready, item.sourceIdentity != nil,
              !item.publicationUnconfirmed, let metadata = item.metadata else { return false }
        return metadata.canSafelyAddGPS
    }
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

    func selectFiltered() { guard !catalogueUpdating else { return }; selection = Set(filteredItems.map(\.id)); scope = .selected }

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
        if resetPage { catalogueRevision &+= 1; catalogueUpdating = true }
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
            objectWillChange.send()
            bufferDirty = false
        }
        if let pendingPhase, !isCancelling { phase = pendingPhase }
        if let pendingCompleted { completed = pendingCompleted }
        if let pendingTotal { total = pendingTotal; activeScopeCount = pendingTotal }
        if progressSucceeded != bufferedSucceeded { progressSucceeded = bufferedSucceeded }
        if progressFailed != bufferedFailed { progressFailed = bufferedFailed }
        if progressSkipped != bufferedSkipped { progressSkipped = bufferedSkipped }
        pendingPhase = nil; pendingCompleted = nil; pendingTotal = nil
        guard projectionRevision != catalogueRevision else { return }
        catalogueUpdating = true
        guard projectionTask == nil else { return }
        // Phase-only progress does not reorder or regroup every photo. During
        // a job, projection work is coalesced independently of display updates.
        let now = ProcessInfo.processInfo.systemUptime
        if isRunning && now - lastProjectionStarted < 0.75 { scheduleCatalogue(); return }
        lastProjectionStarted = now
        let rows = bufferedItems, revision = catalogueRevision, generation = catalogueGeneration
        let query = query, filter = filter, camera = cameraFilter, sort = sort
        projectionTask = Task { @MainActor [weak self, catalogueIndex] in
            let result = await catalogueIndex.project(rows, query: query, filter: filter,
                camera: camera.isEmpty ? nil : camera, sort: sort)
            guard let self else { return }
            self.projectionTask = nil
            if generation == self.catalogueGeneration && query == self.query && filter == self.filter
                && camera == self.cameraFilter && sort == self.sort {
                self.filteredItems = result.rows
                self.cameras = result.cameras
                self.missingOffsetCount = result.missingOffsets
                self.totalBytes = result.totalBytes
                self.setPage(self.catalogueNeedsPageReset ? 0 : self.pageIndex)
                self.catalogueNeedsPageReset = false
                self.projectionRevision = revision
                if !self.isRunning, self.selection.isEmpty, let first = self.pageItems.first { self.selection = [first.id] }
            }
            self.catalogueUpdating = self.projectionRevision != self.catalogueRevision
            if self.catalogueUpdating { self.scheduleCatalogue() }
        }
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

    func setSonyCompatibility(_ value: Bool) {
        guard !isRunning else { return }
        sonyCompatibility = value
    }

    func setReplaceOriginals(_ value: Bool) {
        guard !isRunning else { return }
        replaceOriginals = value
    }

    func chooseOutputDirectory(confirmAfterSelection: Bool = false, gpsAfterSelection: GPSCoordinate? = nil) {
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
                    if let gpsAfterSelection {
                        self.presentGPSConfirmation(gpsAfterSelection)
                    } else if confirmAfterSelection {
                        self.requestWrite()
                    }
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
        bufferedItems = []; bufferDirty = false
        catalogueGeneration &+= 1; catalogueRevision &+= 1
        catalogueUpdating = true
        filteredItems = []; pageItems = []; cameras = []
        totalBytes = 0; missingOffsetCount = 0
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
        if gpsEnabled {
            do {
                _ = try GPSCoordinate.parse(latitude: gpsLatitudeInput,
                    longitude: gpsLongitudeInput, altitude: gpsAltitudeInput)
            } catch {
                notice = .error("GPS 座標格式錯誤", error.localizedDescription)
                return
            }
        }
        if !replaceOriginals && outputDirectory == nil {
            chooseOutputDirectory(confirmAfterSelection: true)
            return
        }
        if let outputDirectory, !replaceOriginals {
            do { try CopyDestination.validate(outputDirectory, roots: copySourceRootsForRetry ?? inputs) }
            catch { notice = .error("無法使用這個輸出資料夾", error.localizedDescription); return }
        }
        var placement = replaceOriginals ? "替換來源照片；每張先保留可復原備份" : "輸出副本至：\(outputDirectory?.path ?? "未選擇")；來源照片不更動"
        placement += "\n時區依處理範圍；GPS 固定涵蓋本次掃描的所有相片，搜尋、篩選與選取不縮小 GPS 對象。既有 XMP 將同步更新。"
        if gpsEnabled { placement += "\nGPS：\(gpsOverwrite ? "明確覆蓋所有相片既有位置" : "只補完全沒有位置的相片")。" }
        if sonyCompatibility {
            placement += "\nSony 相容模式已開啟：僅放行明列的位置指標重排，但無法保證 MakerNotes 私有位元組完全不變。"
        }
        notice = .writeConfirmation(gpsEnabled ? allInspectedPhotoItems.count : writableItems.count,
                                    offset.value, mode == .replaceAll, placement)
    }

    func confirmReplace() {
        guard canWrite else { return }
        let gps: GPSWriteRequest?
        if gpsEnabled {
            do {
                gps = GPSWriteRequest(coordinate: try GPSCoordinate.parse(
                    latitude: gpsLatitudeInput, longitude: gpsLongitudeInput,
                    altitude: gpsAltitudeInput), overwrite: gpsOverwrite)
            } catch {
                notice = .error("GPS 座標格式錯誤", error.localizedDescription)
                return
            }
        } else { gps = nil }
        let options = WriteOptions(sonyCompatibility: sonyCompatibility, gps: gps,
            timezonePaths: Set(writableItems.map { $0.url.path }))
        if replaceOriginals {
            start(.write(offset: offset, mode: mode, options: options))
        } else if let outputDirectory {
            start(.writeCopy(offset: offset, mode: mode, destination: outputDirectory,
                             sourceRoots: copySourceRootsForRetry ?? inputs, options: options))
        }
    }

    func requestAddGPS() {
        guard canAddGPSToSelected, let item = selectedItem else {
            notice = .error("無法新增 GPS", "請先完成掃描並只選取一張完全沒有 GPS 資訊的相片。")
            return
        }
        do {
            let location = try GPSCoordinate.parse(
                latitude: gpsLatitudeInput,
                longitude: gpsLongitudeInput,
                altitude: gpsAltitudeInput
            )
            guard item.metadata?.canSafelyAddGPS == true else {
                notice = .error("無法安全新增 GPS", "偵測到既有 GPS，或 XMP sidecar 的 GPS 狀態無法可靠確認；為避免覆寫或衝突，不會新增。")
                return
            }
            if !replaceOriginals && outputDirectory == nil {
                chooseOutputDirectory(gpsAfterSelection: location)
                return
            }
            presentGPSConfirmation(location)
        } catch {
            notice = .error("GPS 座標格式錯誤", error.localizedDescription)
        }
    }

    private func presentGPSConfirmation(_ location: GPSCoordinate) {
        guard canAddGPSToSelected, let item = selectedItem else { return }
        if let outputDirectory, !replaceOriginals {
            do {
                try CopyDestination.validate(outputDirectory, roots: copySourceRootsForRetry ?? inputs)
            } catch {
                notice = .error("無法使用這個輸出資料夾", error.localizedDescription)
                return
            }
        }
        let placement = replaceOriginals
            ? "替換來源照片；寫入前建立可復原備份"
            : "輸出副本至：\(outputDirectory?.path ?? "未選擇")；來源照片不更動"
        notice = .gpsConfirmation(item.url.lastPathComponent, location, replaceOriginals, placement)
    }

    func confirmAddGPS(_ location: GPSCoordinate) {
        guard canAddGPSToSelected else { return }
        let options = WriteOptions(sonyCompatibility: sonyCompatibility)
        if replaceOriginals {
            start(.addGPS(location: location, options: options))
        } else if let outputDirectory {
            start(.addGPSCopy(location: location, destination: outputDirectory,
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
        // Cancel disposable candidate work; an already-started publication is completed without interruption.
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
        case .addGPS, .addGPSCopy:
            guard previewIsCurrent, !previewFileURLs.isEmpty, selection.count == 1,
                  let selected = selectedItem, selected.status == .ready,
                  selected.sourceIdentity != nil, !selected.publicationUnconfirmed,
                  selected.metadata?.canSafelyAddGPS == true else { return }
            let inspectedPaths = Set(previewFileURLs.map(\.path))
            guard inspectedPaths.contains(selected.url.path) else { return }
            jobInputs = [selected.url]
            includeSubfolders = false
        case .write, .writeCopy, .restore:
            guard previewIsCurrent, !previewFileURLs.isEmpty else { return }
            // Only successfully inspected identities authorize writes. Restore may
            // include missing originals with a readable backup. Never rescan folders.
            let inspectedPaths = Set(previewFileURLs.map(\.path))
            let eligible: [PhotoItem]
            if case .restore = operation { eligible = scopedItems }
            else if gpsEnabled { eligible = allInspectedPhotoItems }
            else { eligible = writableItems }
            jobInputs = eligible.map(\.url).filter { inspectedPaths.contains($0.path) }
            guard !jobInputs.isEmpty else { return }
            includeSubfolders = false
        }
        let identities = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.sourceIdentity.map { (item.url.path, $0) }
        })
        let token = CancellationToken()
        activeRunID = runID
        cancellation = token
        previewSignature = nil
        previewFileURLs = []
        summary = nil
        bufferedItems = []; bufferDirty = false
        catalogueGeneration &+= 1; catalogueRevision &+= 1
        catalogueUpdating = true
        filteredItems = []; pageItems = []; cameras = []
        totalBytes = 0; missingOffsetCount = 0
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
        case .addGPS:
            reportTitle = "GPS 寫入報告"
            phase = "正在安全新增 GPS…"
        case .addGPSCopy:
            reportTitle = "GPS 副本輸出報告"
            phase = "正在建立含 GPS 的副本…"
        case .restore:
            reportTitle = "還原報告"
            phase = "正在尋找原始備份…"
        }
        if notificationsEnabled {
            switch operation {
            case .inspect: break
            case .addGPS, .addGPSCopy:
                postNotification(title: "GPS 中繼資料處理開始", body: "正在處理 \(jobInputs.count) 張；請在 App 查看進度。")
            default:
                postNotification(title: "相片時區處理開始", body: "正在處理 \(jobInputs.count) 張；請在 App 查看進度。")
            }
        }

        // A single ordered stream keeps discovery, row updates and the final report in order.
        let channel = BoundedJobEvents(capacity: 64)
        let worker = Task.detached(priority: .userInitiated) {
            await PhotoEngine(exiftoolURL: engineURL).run(
                inputs: jobInputs,
                recursive: includeSubfolders,
                operation: operation,
                cancellation: token,
                inspectedFilesOnly: { if case .inspect = operation { return false }; return true }(),
                expectedIdentities: identities,
                onEvent: { channel.send($0) }
            )
            channel.finish()
        }
        jobTask = Task { @MainActor [weak self] in
            defer { channel.close() }
            for await event in channel.events {
                channel.acknowledge()
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
        catalogueRevision &+= 1
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
            phase = "處理報告已產生"
        }
        if let summary {
            switch operation {
            case .inspect: break
            case .addGPS, .addGPSCopy:
                postNotification(title: "GPS 中繼資料處理完成",
                                 body: "成功 \(summary.succeeded) 張、失敗 \(summary.failed) 張、略過 \(summary.skipped) 張。")
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
                    try await Task.detached(priority: .utility) {
                        try FileExport.copy(source, to: destination)
                    }.value
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
