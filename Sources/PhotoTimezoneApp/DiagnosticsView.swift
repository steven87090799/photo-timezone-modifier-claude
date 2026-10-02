import AppKit
import SwiftUI
import TimezoneCore

struct DiagnosticsView: View {
    @ObservedObject var model: PhotoViewModel
    @StateObject private var metrics = ProcessDiagnostics()
    @State private var storage: StorageUsageSummary?
    @State private var storageMessage = ""
    @State private var storageBusy = false

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
                    detail("可處理格式", "JPEG、TIFF、Sony ARW；可寫三欄時區或手動新增 GPS，不轉換原格式")
                    Text("3.5：三欄時區、中繼資料驗證、有界記憶體與交易復原記錄。\n3.4.1：Sony 相容模式預設開啟，保留嚴格模式開關與逐張驗證。\n3.4：預設只補 EXIF 拍攝時區，不加減拍攝鐘點。\n3.3：繁體中文選單、集中式時區選擇、資源用量與診斷頁、側欄排版改善。\n3.2：獨立副本輸出或備份後原子替換、進度、逐張失敗與重試。\n3.1：拖入先看相片資訊、相機資料與大量照片的搜尋分頁。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("處理狀態與除錯", symbol: "wrench.and.screwdriver") {
                    detail("目前狀態", model.isRunning ? model.phase : "閒置；沒有正在執行的寫入")
                    detail("已加入來源", "\(model.inputs.count) 個；目前清單 \(model.items.count) 張")
                    detail("輸出方式", model.replaceOriginals ? "替換原檔（先留備份）" : "輸出副本（保留來源）")
                    detail("Sony 驗證模式", model.sonyCompatibility ? "相容模式（預設）；僅允許已知位置指標重排；不做影像 HASH" : "嚴格模式；拒絕 Sony 特例位置調整；僅核對可讀欄位")
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

                section("儲存空間", symbol: "externaldrive") {
                    if let storage {
                        detail("工作紀錄", ByteCountFormatter.string(fromByteCount: storage.logsBytes, countStyle: .file))
                        detail("交易歷史", ByteCountFormatter.string(fromByteCount: storage.transactionHistoryBytes, countStyle: .file))
                        detail("待復原交易", ByteCountFormatter.string(fromByteCount: storage.activeTransactionBytes, countStyle: .file))
                        detail("追蹤原始備份", "\(storage.trackedBackupCount) 個 · " + ByteCountFormatter.string(fromByteCount: storage.trackedBackupBytes, countStyle: .file))
                        if storage.missingTrackedBackups > 0 {
                            Text("有 \(storage.missingTrackedBackups) 筆 provenance 指向已不存在的備份；不會自動刪除 provenance。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text(storageBusy ? "正在計算…" : "尚未計算").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("重新計算") { refreshStorage() }.disabled(storageBusy)
                        Button("清除 30 天前 Logs／交易歷史") { cleanupStorage() }
                            .disabled(storageBusy || model.isRunning)
                    }
                    if !storageMessage.isEmpty {
                        Text(storageMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("只清除行政紀錄；_original、歷史照片備份、provenance 與待復原交易永遠不會由這個按鈕刪除。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("安全界線", symbol: "checkmark.shield") {
                    Text("三個 EXIF 時區欄位為預設處理對象，不改日期或次秒。僅比對可讀中繼資料與檔案屬性；不計算照片 HASH，不宣稱影像或私有位元組全同。備份、候選副本與提交前交易記錄仍保留。")
                    Text("ExifTool 可能重排檔案內部位址；軟體無法保證磁碟故障、突然斷電或未知相機私有資料下絕對零風險。正式處理前請保留另一份獨立備份。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { metrics.start(); refreshStorage() }
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

    private func refreshStorage() {
        guard !storageBusy else { return }
        storageBusy = true
        storageMessage = ""
        Task { @MainActor in
            do {
                storage = try await Task.detached(priority: .utility) {
                    try StorageMaintenance.summary()
                }.value
            } catch {
                storageMessage = error.localizedDescription
            }
            storageBusy = false
        }
    }

    private func cleanupStorage() {
        guard !storageBusy, !model.isRunning else { return }
        storageBusy = true
        storageMessage = ""
        Task { @MainActor in
            do {
                let removed = try await Task.detached(priority: .utility) {
                    try StorageMaintenance.cleanupAdministrativeHistory(olderThanDays: 30)
                }.value
                storageMessage = "已清除 \(removed) 個 30 天前的行政紀錄；照片備份未變更。"
                storage = try await Task.detached(priority: .utility) {
                    try StorageMaintenance.summary()
                }.value
            } catch {
                storageMessage = error.localizedDescription
            }
            storageBusy = false
        }
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
            "Sony 模式：\(model.sonyCompatibility ? "相容模式" : "嚴格模式")",
            "最近結果：成功 \(model.summary?.succeeded ?? 0)、失敗 \(model.summary?.failed ?? 0)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
