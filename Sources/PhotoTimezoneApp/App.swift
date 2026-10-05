import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import TimezoneCore

@main
struct PhotoTimezoneApp: App {
    @NSApplicationDelegateAdaptor(PhotoAppDelegate.self) private var appDelegate
    @StateObject private var model = PhotoViewModel()
    @StateObject private var compression = CompressionModel()

    var body: some Scene {
        Window("相片時區修改器", id: "main") {
            PhotoMainView(model: model, compression: compression)
                .background(WindowCloseGuard(model: model, compression: compression))
                .onAppear { appDelegate.connect(model, compression: compression); compression.setActive(model.activePage == .compression) }
                .onChange(of: model.activePage) { _, page in compression.setActive(page == .compression) }
                .onOpenURL { url in
                    if model.activePage == .compression { compression.addInputs([url]) }
                    else { model.addInputs([url]) }
                }
                .frame(minWidth: 1100, minHeight: 760)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $model.showingRecovery) { RecoveryView() }
        }
        .defaultSize(width: 1320, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("加入相片或資料夾…") {
                    if model.activePage == .compression { compression.chooseInputs() }
                    else { model.chooseInputs() }
                }
                    .keyboardShortcut("o")
                    .disabled(model.activePage == .compression ? compression.isRunning || compression.isImporting : model.isRunning)
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
                Button("交易復原與人工確認") { model.showingRecovery = true }.disabled(model.isRunning)
            }
        }
    }
}

enum AppPage: String, CaseIterable {
    case photos = "相片處理", compression = "影像壓縮", diagnostics = "版本與診斷"
}

enum ProcessingScope: String, CaseIterable {
    case all = "全部預覽", filtered = "篩選結果", selected = "手動選取"
}


enum PhotoNotice: Identifiable {
    case writeConfirmation(Int, String, Bool, String)
    case gpsConfirmation(String, GPSCoordinate, Bool, String)
    case restore
    case busyInput
    case busyClose
    case error(String, String)

    var id: String {
        switch self {
        case .writeConfirmation: return "writeConfirmation"
        case .gpsConfirmation(let file, let location, _, _): return "gpsConfirmation|" + file + "|" + location.display
        case .restore: return "restore"
        case .busyInput: return "busyInput"
        case .busyClose: return "busyClose"
        case .error(let title, let message): return title + message
        }
    }
}

private struct PhotoMainView: View {
    @ObservedObject var model: PhotoViewModel
    @ObservedObject var compression: CompressionModel

    private struct MetadataSpecField: Identifiable {
        let title: String
        let spec: String
        let value: String?
        var id: String { spec + "|" + title }
    }

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
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.dropTargeted, perform: model.acceptDrop)
            } else if model.activePage == .compression {
                CompressionView(model: compression)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiagnosticsView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            if compression.host.webView != nil {
                CompressionRuntimeView(host: compression.host).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay {
            if model.activePage == .photos && model.dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.07))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
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
        .sheet(isPresented: $model.showingReportDetails) { reportDetailsSheet }
        .onChange(of: model.selectedItem?.id) { _, _ in model.showingMoreMetadata = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppArtwork.icon)
                .resizable().interpolation(.high)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("相片時區修改器").font(.headline)
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.5.0")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            Picker("頁面", selection: $model.activePage) {
                ForEach(AppPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 340)
            .accessibilityIdentifier("mainPagePicker")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var settings: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                    Toggle("加入 GPS 位置", isOn: $model.gpsEnabled)
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("batchGPSToggle")
                        .help("對本次掃描的全部支援照片批次處理；搜尋、篩選與單張選取不會縮小 GPS 範圍。")
                    if model.gpsEnabled {
                        TextField("緯度（−90～90）", text: $model.gpsLatitudeInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("gpsLatitudeField")
                        TextField("經度（−180～180）", text: $model.gpsLongitudeInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("gpsLongitudeField")
                        TextField("高度 m，可留空", text: $model.gpsAltitudeInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("gpsAltitudeField")
                        Toggle("GPS 覆蓋", isOn: $model.gpsOverwrite)
                            .disabled(model.isRunning)
                            .accessibilityIdentifier("gpsOverwriteToggle")
                            .help("勾選後才會覆蓋既有位置；未勾選時只補完全沒有 GPS 的相片。")
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("03", "選擇寫入方式")
                    Picker("寫入方式", selection: Binding(get: { model.mode }, set: model.setMode)) {
                        Text("只補上缺少的時區").tag(WriteMode.fillMissing)
                        Text("覆寫所選時區").tag(WriteMode.replaceAll)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(model.isRunning)
                    .accessibilityLabel("時區寫入方式")
                    .accessibilityIdentifier("writeModePicker")
                    Toggle("Sony 相容模式（預設開啟）", isOn: Binding(
                        get: { model.sonyCompatibility }, set: model.setSonyCompatibility
                    ))
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("sonyCompatibilityToggle")
                }
                VStack(alignment: .leading, spacing: 11) {
                    sectionHeading("04", "選擇輸出位置")
                    Toggle("替換來源資料夾中的原照片", isOn: Binding(
                        get: { model.replaceOriginals }, set: model.setReplaceOriginals
                    ))
                    .font(.callout)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("replaceOriginalsToggle")
                    if !model.replaceOriginals {
                        Button(model.outputDirectory == nil ? "選擇副本輸出資料夾…" : "變更副本輸出資料夾…") {
                            model.chooseOutputDirectory()
                        }
                        .disabled(model.isRunning || model.inputs.isEmpty)
                        .accessibilityIdentifier("chooseOutputDirectoryButton")
                        if let destination = model.outputDirectory {
                            Text(destination.path).font(.caption2).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading("05", "時區處理範圍")
                    Picker("處理範圍", selection: $model.scope) {
                        Text("全部").tag(ProcessingScope.all)
                        Text("篩選").tag(ProcessingScope.filtered)
                        Text("已選").tag(ProcessingScope.selected)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("processingScopePicker")
                    Text("時區：\(model.processingCount) 張 · GPS：\(model.gpsEnabled ? "本次掃描全部" : "未啟用")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("處理開始與完成時通知", isOn: Binding(
                        get: { model.notificationsEnabled }, set: model.setNotificationsEnabled
                    ))
                    .accessibilityIdentifier("completionNotificationsToggle")
                }
            }
                .padding(14)
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
            HStack(spacing: 8) {
                Button(action: model.chooseInputs) { Label("加入項目", systemImage: "plus") }
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("addInputsButton")
                Button(action: model.inspect) { Label("重新掃描", systemImage: "arrow.clockwise") }
                    .disabled(!model.canInspect)
                    .accessibilityIdentifier("inspectButton")
            }
            if model.inputs.isEmpty {
                Button(action: model.chooseInputs) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.title2)
                        Text("拖入相片或資料夾").font(.callout.weight(.medium))
                        Text("或按一下選取多個項目").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
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
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("相片預覽").font(.title3.weight(.semibold))
                        Spacer()
                        if !model.items.isEmpty {
                            Text("\(model.items.count) 張 · 時區欄位未齊 \(model.missingOffsetCount) · \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.items.isEmpty {
                        emptyState
                    } else {
                        catalogueToolbar
                        photoTable
                            .frame(maxHeight: .infinity)
                            .layoutPriority(1)
                        selectionControls
                        if let item = model.selectedItem {
                            ScrollView {
                                metadataDetails(item)
                            }
                            .frame(height: min(280, max(160, geometry.size.height * 0.30)))
                            .accessibilityIdentifier("photoMetadataScrollArea")
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if model.isRunning {
                    Divider()
                    activityBar
                }
                Divider()
                reportFooter
            }
        }
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
        HStack(spacing: 10) {
            TextField("搜尋檔名、相機、鏡頭、日期…", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 170, idealWidth: 250, maxWidth: 300)
                .accessibilityIdentifier("photoSearch")
            Picker("狀態", selection: $model.filter) {
                ForEach(PhotoFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 140).accessibilityIdentifier("photoFilter")
            Picker("相機", selection: $model.cameraFilter) {
                Text("所有相機").tag("")
                ForEach(model.cameras, id: \.name) { camera in
                    Text("\(camera.name)（\(camera.count)）").tag(camera.name)
                }
            }
            .frame(minWidth: 160, idealWidth: 240, maxWidth: 340).accessibilityIdentifier("cameraFilter")
            Picker("排序", selection: $model.sort) {
                ForEach(PhotoSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 140)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var selectionControls: some View {
        HStack(spacing: 10) {
            Text("篩選 \(model.filteredItems.count) / \(model.items.count) 張 · 已選 \(model.selection.count) 張")
                .font(.caption).foregroundStyle(.secondary)
            Image(systemName: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .help("用滑鼠滾輪或觸控板連續瀏覽全部篩選結果。單擊相片看資訊，Shift／Command 可複選；只改部分相片時，請將左側時區處理範圍設為『已選』或『篩選』。")
                .accessibilityLabel("清單操作說明")
            Spacer(minLength: 0)
            Button("選取篩選結果", action: model.selectFiltered)
                .disabled(model.filteredItems.isEmpty || model.isRunning)
                .accessibilityIdentifier("selectFilteredButton")
            Button("取消選取") { model.selection = [] }
                .disabled(model.selection.isEmpty || model.isRunning)
        }
        .controlSize(.small)
    }

    private var photoTable: some View {
        Table(model.filteredItems, selection: $model.selection) {
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
                    .font(.system(.caption, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(item.metadata?.dateTimeOriginal == nil ? .secondary : .primary)
            }
            .width(min: 130, ideal: 145, max: 175)
            TableColumn("來源時區") { item in
                Text(display(item.metadata?.offsetOriginal))
                    .font(.system(.caption, design: .monospaced)).lineLimit(1)
            }
            .width(min: 68, ideal: 80, max: 100)
            TableColumn("狀態") { item in
                Label(item.status.uiTitle, systemImage: item.status.uiSymbol)
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(item.status.uiColor)
                    .help(item.detail)
                    .accessibilityLabel("\(item.status.uiTitle)，\(item.detail)")
            }
            .width(min: 82, ideal: 95, max: 110)
        }
        .frame(minHeight: 155)
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollIndicators(.visible)
        .environment(\.defaultMinListRowHeight, 28)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(item.url.lastPathComponent).font(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle).help(item.url.path)
                Text(item.metadata?.fileType ?? "格式待確認").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("以預設程式開啟") { NSWorkspace.shared.open(item.url) }
                    .controlSize(.small).disabled(model.isRunning)
                    .help("外部編輯器可能修改原檔或伴隨檔。")
            }
            HStack(alignment: .top, spacing: 14) {
                PhotoThumbnail(url: item.url, revision: item.transactionID, allowDecode: !model.isRunning)
                    .frame(width: 140, height: 105)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.metadata?.camera ?? "未知相機").font(.headline)
                        .lineLimit(2).help(item.metadata?.camera ?? "未知相機")
                    Text(item.metadata?.lensModel ?? "鏡頭資訊未記錄")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text("ISO \(item.metadata?.iso ?? "—") · \(item.metadata?.exposureTime ?? "—") 秒 · f/\(item.metadata?.aperture ?? "—")")
                        .font(.caption).textSelection(.enabled)
                    Text(item.metadata?.focalLength ?? "焦距未記錄")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(item.metadata?.dimensions ?? "尺寸未記錄") · \(fileSizeText(item.metadata?.fileSize))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 200, alignment: .leading)
                if let metadata = item.metadata {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        metadataSection("時間與時區", fields: [
                            .init(title: "拍攝時間", spec: "ExifIFD:DateTimeOriginal · 0x9003", value: metadata.dateTimeOriginal),
                            .init(title: "拍攝時區", spec: "ExifIFD:OffsetTimeOriginal · 0x9011", value: metadata.offsetOriginal),
                            .init(title: "數位化時間", spec: "ExifIFD:CreateDate · 0x9004", value: metadata.createDate),
                            .init(title: "數位化時區", spec: "ExifIFD:OffsetTimeDigitized · 0x9012", value: metadata.offsetDigitized),
                            .init(title: "修改時間", spec: "IFD0:ModifyDate · 0x0132", value: metadata.modifyDate),
                            .init(title: "修改時區", spec: "ExifIFD:OffsetTime · 0x9010", value: metadata.offsetTime)
                        ], minimumWidth: 130, showsSpecifications: false)
                        gpsEditor(item: item, metadata: metadata)
                        metadataSection("EXIF GPS 資訊", fields: gpsPreviewFields(metadata),
                                        minimumWidth: 105, maximumWidth: 200, showsSpecifications: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
            }
            if let issues = item.metadata?.compatibilityIssues, !issues.isEmpty {
                Text(issues.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let output = item.outputURL, let outputMetadata = item.outputMetadata {
                Divider()
                Text(item.publicationUnconfirmed ? "已發布，待確認同步或伴隨檔狀態" : (output == item.url ? "原檔已替換；備份保留" : "副本輸出 · 來源保持不變"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
                HStack(alignment: .top, spacing: 18) {
                    metadataField("拍攝時區", tag: "ExifIFD:OffsetTimeOriginal · 0x9011", value: outputMetadata.offsetOriginal)
                    metadataField("數位化時區", tag: "ExifIFD:OffsetTimeDigitized · 0x9012", value: outputMetadata.offsetDigitized)
                    metadataField("修改時區", tag: "ExifIFD:OffsetTime · 0x9010", value: outputMetadata.offsetTime)
                }
                if outputMetadata.hasEmbeddedEXIFGPS {
                    HStack(alignment: .top, spacing: 18) {
                        metadataField("GPS 緯度", tag: "GPS:GPSLatitude · 0x0002", value: outputMetadata.gpsLatitude)
                        metadataField("GPS 經度", tag: "GPS:GPSLongitude · 0x0004", value: outputMetadata.gpsLongitude)
                        metadataField("GPS 高度", tag: "GPS:GPSAltitude · 0x0006", value: outputMetadata.gpsAltitude)
                    }
                }
                Text(output.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(output.path).textSelection(.enabled)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if item.metadata != nil {
                Button {
                    model.showingMoreMetadata.toggle()
                } label: {
                    Label(model.showingMoreMetadata ? "收合 EXIF 資訊" : "顯示更多 EXIF 資訊",
                          systemImage: model.showingMoreMetadata ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.link).controlSize(.small)
                .accessibilityIdentifier("moreMetadataButton")
                .help("展開次秒、相機與鏡頭序號、詳細拍攝參數及檔案規格。GPS 欄位已直接顯示在照片右側。")
                if model.showingMoreMetadata {
                    Divider()
                    if let metadata = item.metadata {
                        metadataSection("時間與時區", fields: [
                            .init(title: "拍攝時間", spec: "ExifIFD:DateTimeOriginal · 0x9003", value: metadata.dateTimeOriginal),
                            .init(title: "拍攝時區", spec: "ExifIFD:OffsetTimeOriginal · 0x9011", value: metadata.offsetOriginal),
                            .init(title: "拍攝次秒", spec: "ExifIFD:SubSecTimeOriginal · 0x9291", value: metadata.subSecTimeOriginal),
                            .init(title: "數位化時間", spec: "ExifIFD:CreateDate · EXIF DateTimeDigitized · 0x9004", value: metadata.createDate),
                            .init(title: "數位化時區", spec: "ExifIFD:OffsetTimeDigitized · 0x9012", value: metadata.offsetDigitized),
                            .init(title: "數位化次秒", spec: "ExifIFD:SubSecTimeDigitized · 0x9292", value: metadata.subSecTimeDigitized),
                            .init(title: "修改時間", spec: "IFD0:ModifyDate · EXIF DateTime · 0x0132", value: metadata.modifyDate),
                            .init(title: "修改時區", spec: "ExifIFD:OffsetTime · 0x9010", value: metadata.offsetTime),
                            .init(title: "修改次秒", spec: "ExifIFD:SubSecTime · 0x9290", value: metadata.subSecTime)
                        ])
                        metadataSection("曝光與拍攝參數", fields: [
                            .init(title: "ISO", spec: "ExifIFD:ISO · EXIF PhotographicSensitivity · 0x8827", value: metadata.iso),
                            .init(title: "曝光時間", spec: "ExifIFD:ExposureTime · 0x829A", value: metadata.exposureTime),
                            .init(title: "光圈", spec: "ExifIFD:FNumber · 0x829D", value: metadata.aperture),
                            .init(title: "曝光模式", spec: "ExifIFD:ExposureProgram · 0x8822", value: metadata.exposureProgram),
                            .init(title: "曝光補償", spec: "ExifIFD:ExposureCompensation · EXIF ExposureBiasValue · 0x9204", value: metadata.exposureCompensation),
                            .init(title: "測光模式", spec: "ExifIFD:MeteringMode · 0x9207", value: metadata.meteringMode),
                            .init(title: "閃光燈", spec: "ExifIFD:Flash · 0x9209", value: metadata.flash),
                            .init(title: "焦距", spec: "ExifIFD:FocalLength · 0x920A", value: metadata.focalLength),
                            .init(title: "35mm 等效焦距", spec: "ExifIFD:FocalLengthIn35mmFormat · EXIF FocalLengthIn35mmFilm · 0xA405", value: metadata.focalLength35mm),
                            .init(title: "白平衡", spec: "ExifIFD:WhiteBalance · 0xA403", value: metadata.whiteBalance),
                            .init(title: "場景類型", spec: "ExifIFD:SceneCaptureType · 0xA406", value: metadata.sceneCaptureType)
                        ])
                        metadataSection("相機與鏡頭", fields: [
                            .init(title: "製造商", spec: "IFD0:Make · 0x010F", value: metadata.make),
                            .init(title: "機身型號", spec: "IFD0:Model · 0x0110", value: metadata.cameraModel),
                            .init(title: "機身序號", spec: "ExifIFD:SerialNumber · EXIF BodySerialNumber · 0xA431", value: metadata.bodySerialNumber),
                            .init(title: "鏡頭廠牌", spec: "ExifIFD:LensMake · 0xA433", value: metadata.lensMake),
                            .init(title: "鏡頭型號", spec: lensModelSpec(metadata), value: metadata.lensModel),
                            .init(title: "鏡頭規格", spec: "ExifIFD:LensInfo · EXIF LensSpecification · 0xA432", value: metadata.lensInfo),
                            .init(title: "鏡頭序號", spec: "ExifIFD:LensSerialNumber · 0xA435", value: metadata.lensSerialNumber)
                        ])
                        if let serial = metadata.cameraSerialNumber, metadata.cameraSerialNumber != metadata.bodySerialNumber {
                            metadataField("相機序號（其他來源）", tag: "SerialNumber · ExifTool 備援來源", value: serial)
                        }
                        metadataSection("影像與檔案", fields: [
                            .init(title: "方向", spec: "IFD0:Orientation · 0x0112", value: metadata.orientation),
                            .init(title: "色彩空間", spec: "ExifIFD:ColorSpace · 0xA001", value: metadata.colorSpace),
                            .init(title: "EXIF 寬度", spec: "ExifIFD:ExifImageWidth · EXIF PixelXDimension · 0xA002", value: metadata.imageWidth),
                            .init(title: "EXIF 高度", spec: "ExifIFD:ExifImageHeight · EXIF PixelYDimension · 0xA003", value: metadata.imageHeight),
                            .init(title: "建立軟體", spec: "IFD0:Software · 0x0131", value: metadata.software),
                            .init(title: "檔案格式", spec: "File:FileType · ExifTool", value: metadata.fileType),
                            .init(title: "MIME 類型", spec: "File:MIMEType · ExifTool", value: metadata.mimeType),
                            .init(title: "檔案大小", spec: "File:FileSize · ExifTool", value: metadata.fileSize.map { fileSizeText($0) })
                        ])
                    }
                }
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

    private func gpsPreviewFields(_ metadata: PhotoMetadata) -> [MetadataSpecField] {
        [
            .init(title: "緯度", spec: "GPS:GPSLatitude · 0x0002", value: metadata.gpsLatitude),
            .init(title: "經度", spec: "GPS:GPSLongitude · 0x0004", value: metadata.gpsLongitude),
            .init(title: "高度", spec: "GPS:GPSAltitude · 0x0006", value: metadata.gpsAltitude),
            .init(title: "GPS 日期", spec: "GPS:GPSDateStamp · 0x001D", value: metadata.gpsDateStamp),
            .init(title: "GPS 時間", spec: "GPS:GPSTimeStamp · 0x0007", value: metadata.gpsTimeStamp),
            .init(title: "緯度方向", spec: "GPS:GPSLatitudeRef · 0x0001", value: metadata.gpsLatitudeRef),
            .init(title: "經度方向", spec: "GPS:GPSLongitudeRef · 0x0003", value: metadata.gpsLongitudeRef),
            .init(title: "高度基準", spec: "GPS:GPSAltitudeRef · 0x0005", value: metadata.gpsAltitudeRef),
            .init(title: "GPS 版本", spec: "GPS:GPSVersionID · 0x0000", value: metadata.gpsVersionID)
        ]
    }

    @ViewBuilder
    private func gpsEditor(item: PhotoItem, metadata: PhotoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if metadata.hasCompleteGPSCoordinate {
                    gpsStatusLabel("已有 EXIF GPS", symbol: "location.fill", color: .green)
                } else if metadata.hasAnyGPS {
                    gpsStatusLabel("已偵測到 GPS 資訊", symbol: "location.circle.fill", color: .orange)
                } else if metadata.gpsSafetyUncertain {
                    gpsStatusLabel("GPS 狀態無法確認", symbol: "exclamationmark.triangle.fill", color: .orange)
                } else {
                    gpsStatusLabel("未偵測到 GPS，可手動新增", symbol: "location.slash", color: .secondary)
                }
                if metadata.embeddedXMPGPSDetected {
                    Text("內嵌 XMP").font(.caption2).foregroundStyle(.orange)
                }
                if metadata.sidecarGPSDetected {
                    Text("XMP 伴隨檔").font(.caption2).foregroundStyle(.orange)
                }
            }

            if metadata.gpsSafetyUncertain {
                Text("XMP 伴隨檔無法可靠檢查，這張照片不會自動寫入 GPS。")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func gpsStatusLabel(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private func metadataSection(_ title: String, fields: [MetadataSpecField],
                                 minimumWidth: CGFloat = 170, maximumWidth: CGFloat = 270,
                                 showsSpecifications: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumWidth, maximum: maximumWidth), spacing: 12, alignment: .topLeading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(fields) { field in
                    metadataField(field.title, tag: field.spec, value: field.value, showsSpecification: showsSpecifications)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func metadataField(_ title: String, tag: String, value: String?, showsSpecification: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(display(value))
                .font(.system(size: 11, design: .monospaced)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if showsSpecification {
                Text(tag)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .help(title + "：" + display(value) + "\n" + tag)
    }

    private func lensModelSpec(_ metadata: PhotoMetadata) -> String {
        guard let source = metadata.lensModelSource else {
            return "ExifIFD:LensModel · 0xA434"
        }
        if source == "ExifIFD:LensModel" {
            return "ExifIFD:LensModel · 0xA434"
        }
        return source + " · ExifTool 備援來源"
    }

    private func fileSizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var reportFooter: some View {
        HStack(spacing: 12) {
            Text(model.summary == nil && !model.isRunning ? "掃描報告" : model.reportTitle)
                .font(.callout.weight(.semibold)).lineLimit(1).help(model.reportTitle)
            if model.summary != nil || model.isRunning {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        reportCount("總計", value: model.summary?.total ?? model.total, color: .primary)
                        reportCount("完成", value: model.summary?.succeeded ?? model.progressSucceeded, color: .green)
                        reportCount("略過", value: model.summary?.skipped ?? model.progressSkipped, color: .secondary)
                        reportCount("失敗", value: model.summary?.failed ?? model.progressFailed,
                                    color: (model.summary?.failed ?? model.progressFailed) > 0 ? .red : .secondary)
                        reportCount("取消", value: model.summary?.cancelled ?? 0, color: .secondary)
                    }
                }
                .scrollIndicators(.hidden).frame(height: 24)
                .accessibilityIdentifier("jobReportCountsRow")
            } else {
                Text("尚未掃描").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.retryCount > 0 {
                Button(action: model.retryUnfinished) { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isRunning)
                    .help("重新檢查失敗／取消的 \(model.retryCount) 張相片")
                    .accessibilityLabel("重新檢查失敗或取消的相片")
            }
            Button("詳情") { model.showingReportDetails = true }
                .disabled(model.summary == nil || model.isRunning)
                .help("查看完整訊息、失敗原因與處理結果")
                .accessibilityIdentifier("jobReportDetailsButton")
            Button(action: model.exportLog) { Label("匯出…", systemImage: "square.and.arrow.up") }
                .disabled(model.isRunning || model.summary?.logURL == nil)
                .accessibilityIdentifier("exportLogButton")
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.bar)
        .accessibilityIdentifier("jobReport")
    }

    private var reportDetailsSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Text("處理報告詳情").font(.headline)
                Spacer()
                Button("完成") { model.showingReportDetails = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let summary = model.summary { report(summary) }
                else { ProgressView("正在重新掃描…").padding(24) }
            }
        }.padding(20).frame(width: 760, height: 560)
    }

    private func report(_ summary: JobSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.reportTitle).font(.callout.weight(.semibold))
                Spacer()
                if model.retryCount > 0 {
                    Button("重新檢查失敗／取消 \(model.retryCount) 張") {
                        model.showingReportDetails = false
                        model.retryUnfinished()
                    }
                        .disabled(model.isRunning).controlSize(.small)
                }
                Button(action: model.exportLog) {
                    Label("匯出記錄…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .disabled(model.isRunning || summary.logURL == nil)
                .accessibilityIdentifier("exportLogButton")
            }
            HStack(spacing: 16) {
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
                        Button("顯示全部失敗項目") {
                            model.showingReportDetails = false
                            model.showFailures()
                        }
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
        .accessibilityIdentifier("jobReportDetails")
    }

    private func reportCount(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
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
            Image(systemName: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .help(sectionHelp(title))
        }
    }

    private func sectionHelp(_ title: String) -> String {
        switch title {
        case "加入相片與資料夾": return "加入後自動掃描；包含子資料夾時一併找出支援的照片。"
        case "設定固定時區": return "EXIF 和既有 XMP 缺少時區時補上偏移；不平移拍攝時間。GPS 若啟用，固定處理整次掃描。"
        case "選擇寫入方式": return "預設只補缺漏。明確覆寫才會統一現有 EXIF 與 XMP 偏移；Sony 相容模式允許已知的內部位置指標重排。"
        case "選擇輸出位置": return "副本保留來源；替換原檔會先保存照片與相關 sidecar 備份。"
        case "時區處理範圍": return "只限制時區處理；GPS 永遠以整次掃描到的相片為對象。"
        default: return "可在這裡調整處理設定。"
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
        case .gpsConfirmation(let file, let location, let replaceOriginal, let placement):
            return Alert(
                title: Text("確認新增 GPS？"),
                message: Text("相片：\(file)\n座標：\(location.display)\n位置：\(placement)\n\n只允許新增 EXIF GPSVersionID、Latitude/Longitude 與必要方向欄位，高度只有在你有輸入時才新增。既有日期、三個 EXIF 時區、曝光、鏡頭與其他可讀中繼資料都必須驗證不變；若偵測到任何既有 EXIF/XMP GPS，操作會拒絕，不會覆寫。"),
                primaryButton: .default(Text(replaceOriginal ? "備份後新增 GPS" : "建立含 GPS 的副本")) {
                    model.confirmAddGPS(location)
                },
                secondaryButton: .cancel(Text("取消"))
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
    private weak var compression: CompressionModel?
    private var pendingURLs: [URL] = []

    func connect(_ model: PhotoViewModel, compression: CompressionModel) {
        self.model = model
        self.compression = compression
        if !pendingURLs.isEmpty {
            if model.activePage == .compression { compression.addInputs(pendingURLs) }
            else { model.addInputs(pendingURLs) }
            pendingURLs = []
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            if model.activePage == .compression { compression?.addInputs(urls) }
            else { model.addInputs(urls) }
        } else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let compression, compression.isRunning || compression.isExporting || compression.isImporting {
            model?.notice = .error("影像壓縮仍在處理", "請等待處理完成，或先停止壓縮後再結束程式。")
            sender.activate(ignoringOtherApps: true)
            return .terminateCancel
        }
        guard let model, model.isRunning else { return .terminateNow }
        model.requestClose()
        sender.activate(ignoringOtherApps: true)
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        compression?.host.shutdown()
        ChildProcessRegistry.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Intercepts only close requests and forwards SwiftUI's existing window-delegate behavior.
private struct WindowCloseGuard: NSViewRepresentable {
    let model: PhotoViewModel
    let compression: CompressionModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model, compression: compression) }

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
        private weak var compression: CompressionModel?
        private weak var originalDelegate: NSWindowDelegate?
        private weak var attachedWindow: NSWindow?

        init(model: PhotoViewModel, compression: CompressionModel) { self.model = model; self.compression = compression }

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
            if let compression, compression.isRunning || compression.isExporting || compression.isImporting {
                model?.notice = .error("影像壓縮仍在處理", "請等待處理完成，或先停止壓縮後再關閉視窗。")
                return false
            }
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
