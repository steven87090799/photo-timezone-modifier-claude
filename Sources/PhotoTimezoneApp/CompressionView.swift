import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CompressionView: View {
    @ObservedObject var model: CompressionModel
    private var locked: Bool { model.isRunning || model.isImporting || model.isExporting }

    var body: some View {
        HStack(spacing: 0) {
            settings.frame(width: 300)
            Divider()
            workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.selected != nil {
                Divider()
                inspector.frame(width: 300)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.dropTargeted, perform: model.acceptDrop)
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.showingComparison) { CompressionComparison(model: model) }
        .sheet(isPresented: $model.showingWebhook) { webhookSettings }
        .sheet(isPresented: $model.showingEngineInfo) { engineInfo }
        .alert("影像壓縮", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            Form {
                Section("輸入") {
                    Button(action: model.chooseInputs) {
                        Label("加入圖片或資料夾…", systemImage: "plus")
                    }.accessibilityIdentifier("compressionAddInputs")
                    Toggle("包含子資料夾", isOn: $model.recursive)
                        .help("下一次加入資料夾時，搜尋其中的子資料夾。")
                    if model.isImporting { ProgressView("正在讀取影像…").controlSize(.small) }
                }
                Section("壓縮") {
                    Picker("格式", selection: $model.format) {
                        ForEach(CompressionFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                                .disabled(format == .heif && !CompressionHost.supportsHEIF)
                        }
                    }
                    .accessibilityIdentifier("compressionFormatPicker")
                    .help(model.format.hint)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.format == .png ? "壓縮努力度" : "品質")
                            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                                .help(model.format.hint)
                            Spacer()
                            Text(model.format == .png ? "\(CompressionModel.pngEffort(model.quality)) / 6" : "\(Int(model.quality.rounded()))")
                                .monospacedDigit().fontWeight(.semibold)
                        }
                        // Continuous native track avoids 99 dense system tick marks;
                        // round the value so encoder and displayed quality stay integral.
                        Slider(value: Binding(get: { model.quality }, set: { value in
                            let rounded = value.rounded()
                            if model.quality != rounded { model.quality = rounded }
                        }), in: 1...100)
                        .labelsHidden().frame(maxWidth: .infinity)
                        .accessibilityLabel(model.format == .png ? "壓縮努力度" : "品質")
                        .accessibilityIdentifier("compressionQuality")
                        HStack {
                            Text(model.format == .png ? "較快" : "較小檔案")
                            Spacer()
                            Text(model.format == .png ? "較小檔案" : "較高品質")
                        }.font(.caption2).foregroundStyle(.secondary)
                        Button { model.quality = model.format.recommendedQuality } label: {
                            Label(model.format == .png ? "建議努力度" : "建議品質 \(Int(model.format.recommendedQuality))", systemImage: "arrow.counterclockwise")
                                .font(.caption)
                        }.buttonStyle(.borderless)
                    }
                    Stepper("並行處理：\(model.parallelism) 張", value: $model.parallelism, in: 1...CompressionModel.maximumParallelism)
                        .help("最多 8 張；並行估算預算最高 2 GiB，小容量 Mac 依總記憶體降低。實際並行數依相片尺寸與格式調整；不是整個程式的記憶體硬上限。")
                        .accessibilityIdentifier("compressionParallelism")
                }
                Section("儲存") {
                    Button(action: model.chooseOutputDirectory) {
                        Label(model.outputDirectory?.lastPathComponent ?? "選擇輸出資料夾…", systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle)
                    }.help(model.outputDirectory?.path ?? "完成後，也可按『儲存全部』再選擇位置。")
                    Text("完成後請儲存；關閉會清除暫存結果。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.exportStatus.isEmpty { Text(model.exportStatus).font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    DisclosureGroup("其他選項") {
                        Toggle("Webhook", isOn: $model.webhookEnabled)
                            .help("開啟後，把壓縮檔案與摘要傳送到指定網址；預設關閉。")
                        Button("Webhook 設定…") { model.showingWebhook = true }
                        if !model.webhookStatus.isEmpty { Text(model.webhookStatus).font(.caption).foregroundStyle(.secondary) }
                        Button("格式與中繼資料說明") { model.showingEngineInfo = true }
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).disabled(locked)
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.host.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                else if model.format == .heif && !CompressionHost.supportsHEIF { Text("此 Mac 無法編碼 HEIF。").font(.caption) }
                if model.isRunning {
                    Button(action: model.cancel) {
                        Label(model.isCancelling ? "正在停止…" : "停止壓縮", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.disabled(model.isCancelling)
                } else {
                    Button(action: model.start) {
                        Label("開始壓縮 \(model.items.count) 張", systemImage: "arrow.down.right.and.arrow.up.left")
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }.buttonStyle(.glassProminent).disabled(!model.canStart).accessibilityIdentifier("compressionStart")
                }
            }.padding(16)
        }.background(.regularMaterial)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("影像壓縮").font(.title3.weight(.semibold))
                    Text("\(model.items.count) 張 · 原始 \(CompressionModel.bytes(model.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.removeSelected) { Image(systemName: "minus.circle") }.help("移除選取的圖片").disabled(locked || model.selected == nil)
                Button("清空", action: model.clear).disabled(locked || model.items.isEmpty)
            }.padding(16)
            if model.isRunning {
                VStack(spacing: 5) {
                    ProgressView(value: model.progress)
                    HStack { Text("已處理 \(model.doneCount) / \(model.items.count)"); Spacer(); Text("\(Int(model.progress * 100))%").monospacedDigit() }
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 42)).foregroundStyle(.tertiary)
                    Text("拖入圖片或資料夾").font(.headline)
                    Text("選擇格式與品質，預覽後整批壓縮").font(.callout).foregroundStyle(.secondary)
                    Button("加入圖片…", action: model.chooseInputs).disabled(locked)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items) { item in CompressionRow(item: item).tag(item.id) }
                }.listStyle(.inset).accessibilityIdentifier("compressionFileList")
            }
            Divider()
            HStack(spacing: 8) {
                if model.isExporting { ProgressView().controlSize(.small) }
                else { Text("完成 \(model.completed.count) 張 · \(CompressionModel.bytes(model.resultBytes))").font(.caption).foregroundStyle(.secondary) }
                if let savings = model.batchSavings {
                    Label(String(format: savings >= 0 ? "減少 %.1f%%" : "增加 %.1f%%", abs(savings) * 100),
                          systemImage: savings >= 0 ? "arrow.down.right" : "arrow.up.right")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(savings >= 0 ? Color.green : .orange)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background((savings >= 0 ? Color.green : .orange).opacity(0.10), in: Capsule())
                }
                Spacer(minLength: 2)
                Menu {
                    Button("儲存全部圖片…", action: model.saveAll).disabled(model.completed.isEmpty)
                    Button("儲存為 ZIP…", action: model.saveZIP).disabled(model.completed.isEmpty)
                    Divider()
                    Button("匯出處理報告…", action: model.exportReport)
                } label: { Label("輸出", systemImage: "square.and.arrow.up") }
                .disabled(locked || model.items.isEmpty)
            }.padding(12)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let item = model.selected {
                    Text(item.source.lastPathComponent).font(.headline).textSelection(.enabled).lineLimit(3)
                    Text("\(item.width) × \(item.height) · \(CompressionModel.bytes(item.measuredSourceBytes))").font(.caption).foregroundStyle(.secondary)
                    imagePanel(model.originalPreview, title: "原始影像")
                    imagePanel(model.compressedPreview, title: model.previewIsActual ? "實際輸出" : "壓縮預覽")
                    if model.previewLoading { HStack { ProgressView().controlSize(.small); Text("產生完整壓縮預覽…").font(.caption) } }
                    if let size = model.estimate {
                        HStack {
                            Text(model.previewIsActual ? "輸出大小" : "估算大小").font(.callout)
                            Spacer()
                            Text((model.previewIsActual ? "" : "約 ") + CompressionModel.bytes(size)).font(.callout.monospacedDigit().weight(.semibold))
                        }
                        let saved = (1 - Double(size) / Double(max(1, item.measuredSourceBytes))) * 100
                        Text(saved >= 0 ? String(format: "減少 %.1f%%", saved) : String(format: "增加 %.1f%%", -saved))
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(saved >= 0 ? Color.green : .orange)
                    }
                    Text(model.previewNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("放大比較") { model.showingComparison = true }.disabled(model.originalPreview == nil)
                        Spacer()
                        Button("儲存單張…", action: model.saveSelected).disabled(item.result == nil || locked)
                    }
                    if let result = item.result {
                        Divider()
                        Label("中繼資料", systemImage: "checkmark.shield").font(.callout.weight(.semibold))
                        Text(result.metadataStatus).font(.caption).textSelection(.enabled)
                    }
                    if let error = item.error { Text(error).font(.caption).foregroundStyle(item.state == .failed ? .red : .orange).textSelection(.enabled) }
                    if let webhook = item.webhookStatus { Text("Webhook：" + webhook).font(.caption).foregroundStyle(.secondary) }
                    Text(item.source.path).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }.padding(16)
        }.background(.regularMaterial)
    }

    private func imagePanel(_ image: NSImage?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
                if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(4) }
                else { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }.frame(height: 160)
        }
    }

    private var webhookSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Webhook").font(.title2.weight(.semibold)); Spacer(); Button("完成") { model.showingWebhook = false } }
            Toggle("壓縮後傳送檔案與批次摘要", isOn: $model.webhookEnabled)
            TextField("https://example.com/webhook", text: $model.webhookURL).textFieldStyle(.roundedBorder)
            SecureField("Bearer Token（選填，僅此工作階段）", text: $model.webhookToken).textFieldStyle(.roundedBorder)
            HStack { Button("測試連線", action: model.testWebhook); Text(model.webhookStatus).font(.caption).foregroundStyle(.secondary) }
            Text("傳送 multipart 的 file 與 metadata，及 JSON 批次摘要。檔案傳送失敗會重試兩次，結果另行記錄，已完成的壓縮檔仍可儲存。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 540).disabled(model.isRunning)
    }

    private var engineInfo: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("格式與中繼資料").font(.title2.weight(.semibold)); Spacer(); Button("完成") { model.showingEngineInfo = false } }
            ForEach(CompressionFormat.allCases) { format in
                HStack(alignment: .top) { Text(format.rawValue).font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading); Text(format.hint).font(.callout).foregroundStyle(.secondary) }
            }
            Divider()
            Text("EXIF、ICC、XMP 與 IPTC 在容器支援時複製並驗證；每張結果會說明未保留的欄位。JPEG、PNG、WebP、HEIF、JPEG XL 優先保留 RGB 色彩描述檔；AVIF 轉為 sRGB。16 位元整數來源在 PNG／JPEG XL 品質 100 保留精度；其他格式會降至 8 位元並在結果提醒。浮點或更高精度的無損輸出會停止。動畫僅處理第一幀。")
                .font(.callout).foregroundStyle(.secondary)
            Text("處理在本機完成；開啟 Webhook 後才會傳送影像。此頁不提供修改時區或 GPS 的控制。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 570)
    }
}

private struct CompressionRow: View {
    let item: CompressionItem
    private var changeColor: Color { (item.savings ?? 0) >= 0 ? .green : .orange }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CompressionThumbnail(source: item.source)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.source.lastPathComponent).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(item.source.path)
                Text(item.metadata?.camera ?? "未知相機").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(item.width) × \(item.height)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 100, idealWidth: 150, maxWidth: 190, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(item.dateInfo) · \(item.metadata?.offsetOriginal ?? "時區未填")")
                    .font(.caption).monospacedDigit().lineLimit(1)
                    .help("拍攝：\(item.dateInfo)\n時區：\(item.timezoneInfo)")
                Text("GPS：\(item.gpsInfo)").font(.caption).lineLimit(1).help(item.gpsInfo)
                Text(item.basicInfo).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(item.basicInfo)
                if let error = item.metadataError {
                    Label("EXIF 讀取失敗", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).help(error)
                }
            }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    if item.state == .success { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    Text(item.state == .running ? item.phase : item.state.rawValue)
                        .foregroundStyle(item.state == .failed ? Color.red : .secondary)
                    if let format = item.format { Text(format.rawValue).foregroundStyle(.tertiary) }
                }.font(.caption).lineLimit(1)
                if let savings = item.savings, let result = item.result {
                    Label(String(format: savings >= 0 ? "減少 %.1f%%" : "增加 %.1f%%", abs(savings) * 100),
                          systemImage: savings >= 0 ? "arrow.down.right" : "arrow.up.right")
                        .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(changeColor)
                        .help("原始 \(item.measuredSourceBytes) bytes → 輸出 \(result.bytes) bytes；\(savings >= 0 ? "節省" : "增加") \(CompressionModel.bytes(abs(item.measuredSourceBytes - result.bytes)))")
                    Text("\(CompressionModel.bytes(item.measuredSourceBytes)) → \(CompressionModel.bytes(result.bytes))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                } else if item.state == .running {
                    ProgressView(value: item.progress, total: 100).controlSize(.small)
                    Text(String(format: "%.0f%%", item.progress)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(CompressionModel.bytes(item.measuredSourceBytes)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 148, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

private struct CompressionComparison: View {
    @ObservedObject var model: CompressionModel
    @Environment(\.displayScale) private var displayScale
    @StateObject private var state = CompressionComparisonState()
    private var request: String { "\(model.selection?.uuidString ?? "")|\(model.comparisonOutput?.path ?? "")|\(state.x)|\(state.y)" }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("原尺寸細節比較").font(.headline)
                Spacer()
                Text("縮放").font(.caption)
                Slider(value: $model.comparisonScale, in: 0.5...4).frame(width: 150)
                Text(String(format: "%.0f%%", model.comparisonScale * 100)).font(.caption.monospacedDigit()).frame(width: 45)
                Button("完成") { model.showingComparison = false }
            }
            HStack {
                Text("水平位置").font(.caption)
                Slider(value: $state.x, in: 0...1)
                Text("垂直位置").font(.caption)
                Slider(value: $state.y, in: 0...1)
            }
            HStack(spacing: 16) {
                comparisonImage(state.original, title: "原始影像")
                comparisonImage(state.output, title: "實際輸出")
            }
            if state.loading { ProgressView().controlSize(.small) }
            Text("比較同位置的原尺寸區塊（最多 1024 × 1024）；100% 為一個影像像素對應一個螢幕像素。移動位置可檢查不同細節。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 940, height: 650)
        .task(id: request) {
            state.loading = true
            defer { if !Task.isCancelled { state.loading = false } }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let source = model.selected?.source else { return }
            let target = model.comparisonOutput, cx = state.x, cy = state.y
            let pair = await Task.detached { () -> (NSImage?, NSImage?) in
                let before = autoreleasepool { CompressionImages.comparisonCrop(source, x: cx, y: cy) }
                let after = target.flatMap { url in autoreleasepool { CompressionImages.comparisonCrop(url, x: cx, y: cy) } }
                return (before, after)
            }.value
            guard !Task.isCancelled else { return }
            state.original = pair.0; state.output = pair.1
        }
        .onDisappear { state.original = nil; state.output = nil }
    }
    private func comparisonImage(_ image: NSImage?, title: String) -> some View {
        VStack {
            Text(title).font(.callout.weight(.semibold))
            ScrollView([.horizontal, .vertical]) {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.none)
                        .frame(width: image.size.width / displayScale * model.comparisonScale,
                               height: image.size.height / displayScale * model.comparisonScale)
                } else { Text("此格式無法顯示原尺寸細節，或尚未產生輸出").foregroundStyle(.secondary).frame(width: 430, height: 490) }
            }.background(Color.black.opacity(0.25)).frame(width: 430, height: 490)
        }
    }
}

@MainActor
private final class CompressionComparisonState: ObservableObject {
    @Published var x = 0.5
    @Published var y = 0.5
    @Published var original: NSImage?
    @Published var output: NSImage?
    @Published var loading = false
}

/// List rows load only the visible thumbnails; the shared cache is bounded.
private struct CompressionThumbnail: View {
    let source: URL
    @StateObject private var state = ThumbnailState()
    @MainActor private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>(); cache.countLimit = 96; cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    var body: some View {
        Group {
            if let image = state.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: source) {
            if let cached = Self.cache.object(forKey: source as NSURL) { state.image = cached; return }
            let loaded = await Task.detached { CompressionImages.thumbnail(source, size: 96) }.value
            guard !Task.isCancelled, let loaded else { return }
            Self.cache.setObject(loaded, forKey: source as NSURL, cost: 96 * 96 * 4)
            state.image = loaded
        }
    }
}

@MainActor
private final class ThumbnailState: ObservableObject { @Published var image: NSImage? }
