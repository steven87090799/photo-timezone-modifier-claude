import AppKit
import SwiftUI
import TimezoneCore

struct RecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [RecoveryEntry] = []
    @State private var message = ""
    @State private var busy = false
    @State private var selected: RecoveryEntry?
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("交易復原與人工確認").font(.title2.bold())
            Text("未確認交易可能已發布照片。請先檢查目的檔案、備份與伴隨檔；不會自動重試或刪除任何照片。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            if busy { ProgressView() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.target.path).font(.headline).textSelection(.enabled)
                            Text("狀態：\(entry.phase.rawValue)\n備份：\(entry.backup?.path ?? "無")\n\(entry.detail)")
                                .font(.caption).textSelection(.enabled)
                            if !entry.sidecars.isEmpty {
                                Text(entry.sidecars.map(\.path).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                            }
                            HStack {
                                Button("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([entry.target]) }
                                Button("已人工檢查…") { selected = entry; confirm = true }.disabled(busy)
                            }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Button("重新讀取") { reload() }.disabled(busy)
                Button("開啟交易記錄資料夾") {
                    if let url = try? TransactionRecovery.directory() { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 720, minHeight: 440)
        .task { reload() }
        .confirmationDialog("確認已檢查檔案與備份？", isPresented: $confirm, titleVisibility: .visible) {
            Button("確認，僅封存此交易記錄") {
                guard let selected else { return }
                busy = true
                Task { @MainActor in
                    do {
                        try await Task.detached(priority: .utility) { try TransactionRecovery.acknowledgeReviewed(selected) }.value
                        busy = false; reload()
                    } catch { message = error.localizedDescription; busy = false }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此動作不會修改照片、修復缺漏伴隨檔或刪除備份，也不代表已做影像完整性認證。之後請先重新掃描預覽。")
        }
    }

    private func reload() {
        guard !busy else { return }
        busy = true; message = ""
        Task { @MainActor in
            do {
                entries = try await Task.detached(priority: .utility) { try TransactionRecovery.pending() }.value
                if entries.isEmpty { message = "沒有待人工確認的交易。" }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
