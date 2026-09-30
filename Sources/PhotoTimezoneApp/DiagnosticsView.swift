import AppKit
import SwiftUI
import TimezoneCore

struct DiagnosticsView: View {
    @ObservedObject var model: PhotoViewModel
    @StateObject private var metrics = ProcessDiagnostics()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    }
    private var logDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PhotoTimezone/Logs", isDirectory: true)
    }
    private var architecture: String {
        #if arch(arm64)
        "Apple Silicon（arm64）"
        #elseif arch(x86_64)
        "Intel（x86_64）"
        #else
        "其他"
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: AppArtwork.icon).resizable().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("版本與診斷").font(.title2.bold())
                        Text("相片時區修改器 \(version)（建置 \(build)）")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("複製診斷摘要") { copySummary() }
                        .accessibilityIdentifier("copyDiagnosticsButton")
                }

                section("即時資源用量", symbol: "cpu") {
                    HStack(spacing: 12) {
                        metricCard("App CPU", value: metrics.cpuPercent.map { String(format: "%.1f %%", $0) } ?? "計算中…",
                                   symbol: "cpu")
                        metricCard("App 記憶體", value: metrics.memoryBytes.map {
                            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                        } ?? "無法讀取", symbol: "memorychip")
                    }
                    Text("每秒更新；CPU 100% 代表使用一個邏輯核心。這裡只計算本 App 行程，不包含另行啟動的 ExifTool。切換離開此頁即停止採樣。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("版本與相容性", symbol: "info.circle") {
                    detail("App 版本", "\(version)（\(build)）")
                    detail("ExifTool", "內附固定版本 \(EngineResources.version)")
                    detail("執行架構", architecture)
                    detail("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
                    detail("可處理格式", "JPEG、TIFF、Sony ARW；僅補寫時區，不轉換原格式")
                    Text("3.4：預設只補 EXIF 拍攝時區；Sony 相容模式需明確開啟並核對影像資料。\n3.3：繁體中文選單、集中式時區選擇、資源用量與診斷頁、側欄排版改善。\n3.2：獨立副本輸出或備份後原子替換、進度、逐張失敗與重試。\n3.1：拖入先看相片資訊、相機資料與大量照片的搜尋分頁。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("處理狀態與除錯", symbol: "wrench.and.screwdriver") {
                    detail("目前狀態", model.isRunning ? model.phase : "閒置；沒有正在執行的寫入")
                    detail("已加入來源", "\(model.inputs.count) 個；目前清單 \(model.items.count) 張")
                    detail("輸出方式", model.replaceOriginals ? "替換原檔（先留備份）" : "輸出副本（保留來源）")
                    if let summary = model.summary {
                        detail("最近報告", "完成 \(summary.succeeded)、略過 \(summary.skipped)、失敗 \(summary.failed)、取消 \(summary.cancelled)")
                    }
                    detail("處理紀錄", model.summary?.logURL?.lastPathComponent ?? "尚無本次工作紀錄")
                    HStack {
                        Button("在 Finder 開啟記錄資料夾") {
                            if let logDirectory { NSWorkspace.shared.open(logDirectory) }
                        }
                        .disabled(logDirectory.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
                        .accessibilityIdentifier("openLogsButton")
                        Text("匯出單次紀錄請到相片處理頁的報告區。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("安全界線", symbol: "checkmark.shield") {
                    Text("寫入前先製作候選檔；驗證可讀的非時區中繼資料、影像內容與檔案屬性。替換原檔模式會先保留備份，再原子提交。發現無法確認的 Sony 私有結構變更時會拒絕該張，失敗不代表原檔遺失。")
                    Text("ExifTool 可能重排檔案內部位址；軟體無法保證磁碟故障、突然斷電或未知相機私有資料下絕對零風險。正式處理前請保留另一份獨立備份。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { metrics.start() }
        .onDisappear { metrics.stop() }
        .accessibilityIdentifier("diagnosticsPage")
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metricCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
                .accessibilityIdentifier(title == "App CPU" ? "cpuUsageValue" : "memoryUsageValue")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func copySummary() {
        // Do not put source photo paths, camera serials or image metadata on the
        // clipboard. A log must be exported separately with the user's action.
        let lines = [
            "相片時區修改器 \(version)（建置 \(build)）",
            "ExifTool \(EngineResources.version)",
            "\(ProcessInfo.processInfo.operatingSystemVersionString) / \(architecture)",
            "CPU（App 本體）：\(metrics.cpuPercent.map { String(format: "%.1f %%", $0) } ?? "無法讀取")",
            "記憶體（App 本體）：\(metrics.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "無法讀取")",
            "處理狀態：\(model.isRunning ? "處理中" : "閒置")",
            "最近結果：成功 \(model.summary?.succeeded ?? 0)、失敗 \(model.summary?.failed ?? 0)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
