import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
                .frame(minWidth: 980, minHeight: 700)
        }
        .defaultSize(width: 1160, height: 820)
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
        }
    }
}

@MainActor
final class PhotoViewModel: ObservableObject {
    @Published private(set) var inputs: [URL] = []
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var recursive = true
    @Published private(set) var offset = UTCOffset(minutes: 480)
    @Published private(set) var mode: WriteMode = .fillMissing
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var phase = "加入相片，開始檢查時區"
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var summary: JobSummary?
    @Published private(set) var reportTitle = "處理報告"
    @Published var selection: PhotoItem.ID?
    @Published var notice: PhotoNotice?
    @Published var dropTargeted = false

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

    private var currentSignature: ScanSignature {
        ScanSignature(paths: inputs.map(\.path).sorted(), recursive: recursive)
    }

    var canInspect: Bool { !isRunning && !inputs.isEmpty }
    var previewIsCurrent: Bool { previewSignature == currentSignature }
    var canWrite: Bool {
        canInspect && previewIsCurrent && !previewFileURLs.isEmpty && items.contains { $0.status == .ready }
    }
    var canRestore: Bool { canInspect && previewIsCurrent && !previewFileURLs.isEmpty }
    var selectedItem: PhotoItem? { items.first { $0.id == selection } }
    var readyCount: Int { items.filter { $0.status == .ready }.count }
    var missingOffsetCount: Int {
        items.filter { item in
            guard let metadata = item.metadata else { return false }
            return [metadata.offsetOriginal, metadata.offsetDigitized, metadata.offsetTime]
                .contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
        }.count
    }

    func setRecursive(_ value: Bool) {
        guard !isRunning, recursive != value else { return }
        recursive = value
        invalidatePreview()
    }

    func setOffset(_ value: UTCOffset) {
        guard !isRunning else { return }
        offset = value
    }

    func setMode(_ value: WriteMode) {
        guard !isRunning else { return }
        mode = value
    }

    func addInputs(_ urls: [URL]) {
        guard !isRunning else {
            notice = .busyInput
            return
        }
        var known = Set(inputs.map(\.path))
        let additions = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter {
            known.insert($0.path).inserted
        }
        guard !additions.isEmpty else { return }
        inputs.append(contentsOf: additions)
        invalidatePreview()
    }

    func removeInput(_ url: URL) {
        guard !isRunning else { return }
        inputs.removeAll { $0 == url }
        invalidatePreview()
    }

    func clearInputs() {
        guard !isRunning else { return }
        inputs.removeAll()
        invalidatePreview()
    }

    private func invalidatePreview() {
        previewSignature = nil
        previewFileURLs = []
        items = []
        itemIndices = [:]
        selection = nil
        // Keep the last report available for export until the next job starts.
        phase = inputs.isEmpty ? "加入相片，開始檢查時區" : "來源已更新，請先掃描預覽"
        completed = 0
        total = 0
    }

    func chooseInputs() {
        guard !isRunning else { notice = .busyInput; return }
        let panel = NSOpenPanel()
        panel.title = "加入相片或資料夾"
        panel.message = "可同時選取多張相片與多個資料夾。加入後，先掃描預覽 EXIF 資訊。"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.addInputs(panel.urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
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
        guard canWrite else { return }
        if mode == .replaceAll {
            notice = .replace(offset.value)
        } else {
            start(.write(offset: offset, mode: mode))
        }
    }

    func confirmReplace() {
        guard canWrite, mode == .replaceAll else { return }
        start(.write(offset: offset, mode: mode))
    }

    func requestRestore() {
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
        case .write, .restore:
            guard previewIsCurrent, !previewFileURLs.isEmpty else { return }
            // Freeze the exact inspected files, including failed files for per-file reporting.
            // Never rescan the originally selected folders during a mutating operation.
            jobInputs = previewFileURLs
            includeSubfolders = false
        }
        let token = CancellationToken()
        activeRunID = runID
        cancellation = token
        previewSignature = nil
        previewFileURLs = []
        summary = nil
        items = []
        itemIndices = [:]
        selection = nil
        completed = 0
        total = 0
        isCancelling = false
        isRunning = true
        switch operation {
        case .inspect:
            reportTitle = "掃描報告"
            phase = "正在尋找相片並讀取 EXIF…"
        case .write:
            reportTitle = "寫入報告"
            phase = "正在準備寫入時區…"
        case .restore:
            reportTitle = "還原報告"
            phase = "正在尋找原始備份…"
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
            total = max(total, items.count)
        case .updated(let photo, let done, let count):
            upsert(photo)
            completed = done
            total = count
        case .phase(let text):
            if !isCancelling { phase = text }
        case .finished(let result):
            summary = result
            total = result.total
        }
    }

    private func upsert(_ photo: PhotoItem) {
        if let index = itemIndices[photo.id] {
            items[index] = photo
        } else {
            itemIndices[photo.id] = items.count
            items.append(photo)
        }
        if selection == nil { selection = photo.id }
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
    case replace(String)
    case restore
    case busyInput
    case busyClose
    case error(String, String)

    var id: String {
        switch self {
        case .replace: return "replace"
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
            HStack(alignment: .top, spacing: 0) {
                settings
                    .frame(width: 280)
                Divider()
                workspace
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
        .alert(item: $model.notice, content: alert)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("相片時區修改器").font(.title2.bold())
                    Text("3.0.0").font(.caption).foregroundStyle(.tertiary)
                }
                Text("補上拍攝時區，保留原始拍攝時間。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(action: model.chooseInputs) {
                Label("加入項目…", systemImage: "plus")
            }
            .disabled(model.isRunning)
            .accessibilityIdentifier("addInputsButton")
            Button(action: model.inspect) {
                Label("掃描預覽", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(!model.canInspect)
            .accessibilityIdentifier("inspectButton")
            .help("讀取相片資訊；掃描不會修改檔案。")
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sources
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("02", "設定固定時區")
                    Picker("UTC 偏移", selection: Binding(get: { model.offset }, set: model.setOffset)) {
                        ForEach(UTCOffset.all) { offset in
                            Text(offset.label).tag(offset)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("固定 UTC 時區偏移")
                    .accessibilityIdentifier("utcOffsetPicker")
                    .disabled(model.isRunning)
                    Text("選擇拍攝當時的固定 UTC 偏移，包含半小時與 15 分鐘選項。此設定不是城市時區，不會自動套用日光節約時間（夏令時間）。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("03", "選擇寫入方式")
                    Picker("寫入方式", selection: Binding(get: { model.mode }, set: model.setMode)) {
                        Text("只補上缺少的時區").tag(WriteMode.fillMissing)
                        Text("覆寫所有時區").tag(WriteMode.replaceAll)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(model.isRunning)
                    .accessibilityLabel("時區寫入方式")
                    .accessibilityIdentifier("writeModePicker")
                    Text(model.mode == .fillMissing
                         ? "保留已填寫的時區，只補上缺少的 OffsetTime 標籤。"
                         : "所有 OffsetTime 標籤都會改成選定偏移。寫入前需要再次確認。")
                        .font(.caption)
                        .foregroundStyle(model.mode == .replaceAll ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("原始備份一律啟用", systemImage: "checkmark.shield.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.green)
                    Text("寫入時建立或保留 ExifTool 的 _original 備份。原始拍攝時間 DateTimeOriginal 不變。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                VStack(spacing: 10) {
                    Button(action: model.requestWrite) {
                        Label("寫入 \(model.offset.label)", systemImage: "clock.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canWrite)
                    .accessibilityIdentifier("writeButton")
                    if !model.canWrite && !model.isRunning {
                        Text(model.previewIsCurrent ? "沒有可寫入的相片。" : "完成目前來源的掃描後，即可寫入。")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("從原始備份還原…", action: model.requestRestore)
                        .buttonStyle(.link)
                        .disabled(!model.canRestore)
                        .accessibilityIdentifier("restoreButton")
                        .help("先掃描預覽；僅還原此次掃描清單中的相片。")
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
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
            Text("可將檔案拖到視窗任何位置。掃描只讀取資訊，不會更動相片。")
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
                    Text("\(model.items.count) 張相片・\(model.missingOffsetCount) 張有時區未填")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.items.isEmpty {
                emptyState
            } else {
                photoTable
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
                .frame(maxHeight: model.summary == nil ? 200 : 300)
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
            Text(model.isRunning ? "找到的相片與讀取結果將顯示在這裡。" : "加入來源 → 掃描預覽 → 確認固定 UTC 偏移 → 寫入時區")
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

    private var photoTable: some View {
        Table(model.items, selection: $model.selection) {
            TableColumn("相片") { item in
                HStack(spacing: 8) {
                    Image(systemName: "photo").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .help(item.url.path)
            }
            .width(min: 150, ideal: 220)
            TableColumn("原始拍攝時間") { item in
                Text(display(item.metadata?.dateTimeOriginal))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(item.metadata?.dateTimeOriginal == nil ? .secondary : .primary)
            }
            .width(min: 140, ideal: 155, max: 180)
            TableColumn("拍攝時區") { item in
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
    }

    private func metadataDetails(_ item: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(item.url.lastPathComponent).font(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.metadata?.fileType ?? "格式待確認").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                metadataField("拍攝時區", tag: "OffsetTimeOriginal", value: item.metadata?.offsetOriginal)
                metadataField("數位化時區", tag: "OffsetTimeDigitized", value: item.metadata?.offsetDigitized)
                metadataField("修改時區", tag: "OffsetTime", value: item.metadata?.offsetTime)
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
                        Text("\(model.completed) / \(model.total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if model.isRunning && model.total > 0 {
                    ProgressView(value: Double(min(model.completed, model.total)), total: Double(max(model.total, 1)))
                        .accessibilityLabel("處理進度")
                        .accessibilityValue("已處理 \(model.completed) 張，共 \(model.total) 張")
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
        case .replace(let offset):
            return Alert(
                title: Text("覆寫所有相片的時區？"),
                message: Text("此次已完成掃描清單中，可處理相片的三個 OffsetTime 標籤都將設為 \(offset)，包括已有時區的相片。原始拍攝時間不變，並保留最早的 _original 備份。"),
                primaryButton: .destructive(Text("確認覆寫"), action: model.confirmReplace),
                secondaryButton: .cancel(Text("返回檢查"))
            )
        case .restore:
            return Alert(
                title: Text("從最早保留的原始備份還原？"),
                message: Text("僅處理此次已完成掃描清單中的相片。將以第一次寫入時保留、最早的 _original 備份取代目前檔案，並非只復原上一次操作。\n\n還原前，目前版本會先另存為 .before-restore-UUID.backup 副本，再消耗 _original 備份。若原檔已遺失，會重建原檔並保留備份。沒有備份的相片將略過。"),
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
