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
                .sheet(isPresented: $model.showingRecovery) { RecoveryView() }
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
                Button("交易復原與人工確認") { model.showingRecovery = true }.disabled(model.isRunning)
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
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.5.0")
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
                    Text("固定處理 OffsetTimeOriginal、OffsetTimeDigitized、OffsetTime 三個標準 EXIF 時區欄位；對應的拍攝、數位化、修改日期與次秒全部保留，不會平移時間或補造原本不存在的日期。")
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
                         ? "保留三個欄位中已有的時區，只補缺漏。"
                         : "三個 EXIF 時區欄位會改成指定偏移；拍攝時間本身不變。")
                        .font(.caption)
                        .foregroundStyle(model.mode == .replaceAll ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Sony 相容模式（預設開啟）", isOn: Binding(
                        get: { model.sonyCompatibility }, set: model.setSonyCompatibility
                    ))
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("sonyCompatibilityToggle")
                    Text("僅核對可讀中繼資料，不執行影像或整檔 HASH。Sony 相容模式只容許白名單中的位置指標調整；無法保證影像或 MakerNotes 私有位元組完全不變。備份與安全提交仍保留。")
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
                .frame(maxHeight: model.summary == nil ? 390 : 470)
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
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(item.url.lastPathComponent).font(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.metadata?.fileType ?? "格式待確認").font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                PhotoThumbnail(url: item.url, revision: item.transactionID, allowDecode: !model.isRunning)
                    .frame(width: 140, height: 105)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.metadata?.camera ?? "未知相機").font(.headline)
                    if let serial = item.metadata?.cameraSerialNumber {
                        Text("相機序號：\(serial)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(item.metadata?.lensModel ?? "鏡頭資訊未記錄").font(.caption).foregroundStyle(.secondary)
                    if let source = item.metadata?.lensModelSource {
                        Text("鏡頭資訊來源：\(source)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("ISO \(item.metadata?.iso ?? "—")  ·  \(item.metadata?.exposureTime ?? "—") 秒  ·  f/\(item.metadata?.aperture ?? "—")  ·  \(item.metadata?.focalLength ?? "焦距未記錄")")
                        .font(.caption).textSelection(.enabled)
                    Text("\(item.metadata?.dimensions ?? "尺寸未記錄")  ·  \(fileSizeText(item.metadata?.fileSize))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("拍攝：\(item.metadata?.dateTimeOriginal ?? "未記錄")")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("以預設程式開啟") { NSWorkspace.shared.open(item.url) }
                    .controlSize(.small).disabled(model.isRunning)
                    .help("外部編輯器可能修改原檔或伴隨檔；這不是唯讀預覽。")
            }

            if let issues = item.metadata?.compatibilityIssues, !issues.isEmpty {
                Text(issues.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }

            if let metadata = item.metadata {
                Divider()
                HStack {
                    Text("重要 EXIF / SPEC 欄位").font(.callout.weight(.semibold))
                    Spacer()
                    Text("欄位下方顯示 ExifTool 群組、EXIF Tag 名稱與規格 ID")
                        .font(.caption2).foregroundStyle(.secondary)
                }

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

                metadataSection("相機與鏡頭", fields: [
                    .init(title: "製造商", spec: "IFD0:Make · 0x010F", value: metadata.make),
                    .init(title: "機身型號", spec: "IFD0:Model · 0x0110", value: metadata.cameraModel),
                    .init(title: "機身序號", spec: "ExifIFD:SerialNumber · EXIF BodySerialNumber · 0xA431", value: metadata.bodySerialNumber),
                    .init(title: "鏡頭廠牌", spec: "ExifIFD:LensMake · 0xA433", value: metadata.lensMake),
                    .init(title: "鏡頭型號", spec: lensModelSpec(metadata), value: metadata.lensModel),
                    .init(title: "鏡頭規格", spec: "ExifIFD:LensInfo · EXIF LensSpecification · 0xA432", value: metadata.lensInfo),
                    .init(title: "鏡頭序號", spec: "ExifIFD:LensSerialNumber · 0xA435", value: metadata.lensSerialNumber)
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

                metadataSection("GPS", fields: [
                    .init(title: "緯度", spec: "GPS:GPSLatitude · 0x0002", value: metadata.gpsLatitude),
                    .init(title: "經度", spec: "GPS:GPSLongitude · 0x0004", value: metadata.gpsLongitude),
                    .init(title: "高度", spec: "GPS:GPSAltitude · 0x0006", value: metadata.gpsAltitude),
                    .init(title: "GPS 日期", spec: "GPS:GPSDateStamp · 0x001D", value: metadata.gpsDateStamp),
                    .init(title: "GPS 時間", spec: "GPS:GPSTimeStamp · 0x0007", value: metadata.gpsTimeStamp)
                ])
            }

            if let output = item.outputURL, let outputMetadata = item.outputMetadata {
                Divider()
                Text(item.publicationUnconfirmed ? "已發布，待確認同步或伴隨檔狀態" : (output == item.url ? "原檔已替換；備份保留" : "副本時區 · 來源保持不變"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
                HStack(alignment: .top, spacing: 18) {
                    metadataField("拍攝時區", tag: "ExifIFD:OffsetTimeOriginal · 0x9011", value: outputMetadata.offsetOriginal)
                    metadataField("數位化時區", tag: "ExifIFD:OffsetTimeDigitized · 0x9012", value: outputMetadata.offsetDigitized)
                    metadataField("修改時區", tag: "ExifIFD:OffsetTime · 0x9010", value: outputMetadata.offsetTime)
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

    private func metadataSection(_ title: String, fields: [MetadataSpecField]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 150), alignment: .topLeading),
                    GridItem(.flexible(minimum: 150), alignment: .topLeading),
                    GridItem(.flexible(minimum: 150), alignment: .topLeading)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(fields) { field in
                    metadataField(field.title, tag: field.spec, value: field.value)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func metadataField(_ title: String, tag: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(display(value))
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(tag)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func lensModelSpec(_ metadata: PhotoMetadata) -> String {
        guard let source = metadata.lensModelSource else {
            return "ExifIFD:LensModel · 0xA434"
        }
        if source == "ExifIFD:LensModel" {
            return "ExifIFD:LensModel · 0xA434"
        }
        return source + " · ExifTool fallback"
    }

    private func fileSizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
