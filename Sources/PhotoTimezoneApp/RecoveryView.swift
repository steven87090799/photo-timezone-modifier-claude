import AppKit
import SwiftUI
import TimezoneCore

// Use the same macOS 13-compatible observable-state pattern as OffsetChooser.
// This also avoids the SDK 27 State macro missing in standalone CLT installs.
@MainActor
private final class RecoveryState: ObservableObject {
    @Published var entries: [RecoveryEntry] = []
    @Published var message = ""
    @Published var busy = false
    @Published var selected: RecoveryEntry?
    @Published var confirm = false
}

struct RecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = RecoveryState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("交易復原與人工確認").font(.title2.bold())
            Text("未確認交易可能已發布照片。請先檢查目的檔案、備份與伴隨檔；不會自動重試或刪除任何照片。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if !state.message.isEmpty { Text(state.message).foregroundStyle(.orange).textSelection(.enabled) }
            if state.busy { ProgressView() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(state.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.target.path).font(.headline).textSelection(.enabled)
                            Text("狀態：\(entry.phase.rawValue)\n備份：\(entry.backup?.path ?? "無")\n\(entry.detail)")
                                .font(.caption).textSelection(.enabled)
                            if !entry.sidecars.isEmpty {
                                Text(entry.sidecars.map(\.path).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                            }
                            HStack {
                                Button("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([entry.target]) }
                                Button("已人工檢查…") { state.selected = entry; state.confirm = true }.disabled(state.busy)
                            }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Button("重新讀取") { reload() }.disabled(state.busy)
                Button("開啟交易記錄資料夾") {
                    if let url = try? TransactionRecovery.directory() { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 720, minHeight: 440)
        .background { AppWindowBackdrop() }
        .task { reload() }
        .confirmationDialog("確認已檢查檔案與備份？", isPresented: $state.confirm, titleVisibility: .visible) {
            Button("確認，僅封存此交易記錄") {
                guard let selected = state.selected else { return }
                state.busy = true
                Task { @MainActor in
                    do {
                        try await Task.detached(priority: .utility) { try TransactionRecovery.acknowledgeReviewed(selected) }.value
                        state.busy = false; reload()
                    } catch { state.message = error.localizedDescription; state.busy = false }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此動作不會修改照片、修復缺漏伴隨檔或刪除備份，也不代表已做影像完整性認證。之後請先重新掃描預覽。")
        }
    }

    private func reload() {
        guard !state.busy else { return }
        state.busy = true; state.message = ""
        Task { @MainActor in
            do {
                state.entries = try await Task.detached(priority: .utility) { try TransactionRecovery.pending() }.value
                if state.entries.isEmpty { state.message = "沒有待人工確認的交易。" }
            } catch { state.message = error.localizedDescription }
            state.busy = false
        }
    }
}
