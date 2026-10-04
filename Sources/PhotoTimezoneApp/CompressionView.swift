import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CompressionView: View {
    @ObservedObject var model: CompressionModel
    private var locked: Bool { model.isRunning || model.isImporting || model.isExporting }

    var body: some View {
        HStack(spacing: 0) {
            settings.frame(width: 290)
            Divider()
            workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.selected != nil {
                Divider()
                inspector.frame(width: 330)
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

    private func heading(_ number: String, _ title: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Spacer()
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help(help)
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heading("01", "加入影像", help: "加入檔案或資料夾，也可直接拖入。原始圖片保持原狀；壓縮完成後再選擇儲存位置。")
                    Button(action: model.chooseInputs) {
                        Label("加入圖片或資料夾…", systemImage: "plus").frame(maxWidth: .infinity)
                    }.accessibilityIdentifier("compressionAddInputs")
                    Toggle("包含子資料夾", isOn: $model.recursive).font(.callout)
                        .help("在下一次加入資料夾時，同時搜尋其中的子資料夾。")
                    if model.isImporting { ProgressView("正在讀取影像…").controlSize(.small) }
                    Divider()
                    heading("02", "壓縮設定", help: "品質及格式套用到整批影像。預覽會以縮小影像試算；正式輸出保留完整尺寸。")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(CompressionFormat.allCases) { format in
                            Button { model.format = format } label: {
                                HStack(spacing: 4) {
                                    Text(format.rawValue).font(.callout.weight(.medium))
                                    if format == .heif { Image(systemName: "apple.logo").font(.caption2) }
                                }.frame(maxWidth: .infinity, minHeight: 26)
                            }
                            .buttonStyle(.bordered)
                            .tint(model.format == format ? .accentColor : .gray)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.format == format ? Color.accentColor : .clear, lineWidth: 1))
                            .help(format.hint)
                            .accessibilityIdentifier("compressionFormat-" + format.fileExtension)
                            .disabled(format != .jpeg && model.host.isReady && !model.host.formats.contains(format.mime))
                        }
                    }
                    HStack {
                        Text(model.format == .png ? "壓縮努力度" : "品質").font(.callout)
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                            .help(model.format.hint + " HEIF 使用 macOS ImageIO；AVIF 與 JPEG XL 會將像素轉為 sRGB 並明確記錄。")
                        Spacer()
                        Text(model.format == .png ? "\(Int((model.quality / 100 * 6).rounded())) / 6" : "\(Int(model.quality.rounded()))")
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                    Slider(value: $model.quality, in: 1...100, step: 1).accessibilityIdentifier("compressionQuality")
                    HStack {
                        Text(model.format == .png ? "較快" : "較小檔案")
                        Spacer()
                        Text(model.format == .png ? "較小檔案" : "較高品質")
                    }.font(.caption).foregroundStyle(.secondary)
                    Stepper("並行處理：\(model.parallelism) 張", value: $model.parallelism, in: 1...4)
                        .font(.callout).help("同時壓縮的張數。大尺寸影像會自動降低並行數，以控制記憶體用量。")
                    Divider()
                    heading("03", "輸出", help: "支援單張儲存、整批儲存及 ZIP。可保留的 EXIF、ICC、XMP 會複製並驗證，包含既有時區及 GPS；本頁不修改時區或 GPS。")
                    Button(action: model.chooseOutputDirectory) {
                        Label(model.outputDirectory?.lastPathComponent ?? "選擇輸出資料夾…", systemImage: "folder")
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }.help(model.outputDirectory?.path ?? "也可等壓縮完成後再選擇儲存位置。")
                    Text("壓縮後請按「儲存單張」或「輸出 → 儲存全部」。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.exportStatus.isEmpty { Text(model.exportStatus).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Toggle("Webhook", isOn: $model.webhookEnabled).font(.callout)
                            .help("開啟後，把壓縮檔案及批次摘要傳送到你設定的網址。預設關閉。")
                        Button("設定…") { model.showingWebhook = true }
                    }
                    if !model.webhookStatus.isEmpty { Text(model.webhookStatus).font(.caption).foregroundStyle(.secondary) }
                    Button { model.showingEngineInfo = true } label: {
                        Label("格式與中繼資料說明", systemImage: "info.circle").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(16).disabled(locked)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.host.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                else if !model.host.isAvailable(model.format) { HStack { ProgressView().controlSize(.small); Text("正在準備編碼器…").font(.caption) } }
                if model.isRunning {
                    Button(action: model.cancel) {
                        Label(model.isCancelling ? "正在停止…" : "停止壓縮", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.disabled(model.isCancelling)
                } else {
                    Button(action: model.start) {
                        Label("開始壓縮 \(model.items.count) 張", systemImage: "arrow.down.right.and.arrow.up.left")
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }.buttonStyle(.borderedProminent).disabled(!model.canStart).accessibilityIdentifier("compressionStart")
                }
            }.padding(16)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
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
                    Text("\(item.width) × \(item.height) · \(CompressionModel.bytes(item.originalBytes))").font(.caption).foregroundStyle(.secondary)
                    imagePanel(model.originalPreview, title: "原始影像")
                    imagePanel(model.compressedPreview, title: model.previewIsActual ? "實際輸出" : "壓縮預覽")
                    if model.previewLoading { HStack { ProgressView().controlSize(.small); Text("產生預覽與估算…").font(.caption) } }
                    if let size = model.estimate {
                        HStack {
                            Text(model.previewIsActual ? "輸出大小" : "估算大小").font(.callout)
                            Spacer()
                            Text((model.previewIsActual ? "" : "約 ") + CompressionModel.bytes(size)).font(.callout.monospacedDigit().weight(.semibold))
                        }
                        let saved = (1 - Double(size) / Double(max(1, item.originalBytes))) * 100
                        Text(saved >= 0 ? String(format: "減少約 %.1f%%", saved) : String(format: "增加約 %.1f%%", -saved))
                            .font(.caption).foregroundStyle(.secondary)
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
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
    }

    private func imagePanel(_ image: NSImage?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
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
            Text("EXIF、ICC、XMP 與 IPTC 在容器支援時複製並驗證；每張結果會說明未保留的欄位。JPEG、PNG、WebP、HEIF 優先保留 RGB 色彩描述檔；AVIF、JPEG XL 轉為 sRGB。高位元影像會輸出為 8 位元，動畫僅處理第一幀。")
                .font(.callout).foregroundStyle(.secondary)
            Text("處理在本機完成；開啟 Webhook 後才會傳送影像。此頁不提供修改時區或 GPS 的控制。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 570)
    }
}

private struct CompressionRow: View {
    let item: CompressionItem
    var body: some View {
        HStack(spacing: 10) {
            Group {
                CompressionThumbnail(source: item.source)
            }.frame(width: 42, height: 42).background(Color.black.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.source.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(CompressionModel.bytes(item.originalBytes))
                    if let result = item.result {
                        Image(systemName: "arrow.right"); Text(CompressionModel.bytes(result.bytes))
                        if let savings = item.savings { Text(String(format: "(%+.0f%%)", -savings * 100)) }
                    }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if item.state == .running { ProgressView(value: item.progress, total: 100).controlSize(.small) }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.state == .running ? item.phase : item.state.rawValue).font(.caption)
                    .foregroundStyle(item.state == .failed ? Color.red : item.state == .success ? .green : .secondary)
                if let format = item.format { Text(format.rawValue).font(.caption2).foregroundStyle(.tertiary) }
            }
        }.padding(.vertical, 5)
    }
}

private struct CompressionComparison: View {
    @ObservedObject var model: CompressionModel
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("影像比較").font(.headline)
                Spacer()
                Text("縮放").font(.caption)
                Slider(value: $model.comparisonScale, in: 1...4).frame(width: 150)
                Text(String(format: "%.0f%%", model.comparisonScale * 100)).font(.caption.monospacedDigit()).frame(width: 45)
                Button("完成") { model.showingComparison = false }
            }
            HStack(spacing: 16) {
                comparisonImage(model.originalPreview, title: "原始影像")
                comparisonImage(model.compressedPreview, title: model.previewIsActual ? "實際輸出" : "壓縮預覽（900 px）")
            }
            Text(model.previewNote).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 940, height: 620)
    }
    private func comparisonImage(_ image: NSImage?, title: String) -> some View {
        VStack {
            Text(title).font(.callout.weight(.semibold))
            ScrollView([.horizontal, .vertical]) {
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(width: 430 * model.comparisonScale, height: 510 * model.comparisonScale) }
                else { Text("此格式無法顯示預覽").foregroundStyle(.secondary).frame(width: 430, height: 510) }
            }.background(Color.black.opacity(0.25))
        }
    }
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
