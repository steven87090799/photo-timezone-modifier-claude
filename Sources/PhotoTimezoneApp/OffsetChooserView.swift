import SwiftUI
import TimezoneCore

@MainActor
private final class OffsetChooserState: ObservableObject {
    @Published var draft: UTCOffset
    @Published var showQuarterHours: Bool
    @Published var search = ""

    init(selected: UTCOffset) {
        draft = selected
        showQuarterHours = !selected.minutes.isMultiple(of: 60)
    }
}

struct OffsetChooserView: View {
    @StateObject private var state: OffsetChooserState

    let onConfirm: (UTCOffset) -> Void
    let onCancel: () -> Void

    init(selected: UTCOffset, onConfirm: @escaping (UTCOffset) -> Void, onCancel: @escaping () -> Void) {
        _state = StateObject(wrappedValue: OffsetChooserState(selected: selected))
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var choices: [UTCOffset] {
        let base = state.showQuarterHours ? UTCOffset.all : OffsetGuide.wholeHours
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.label.localizedCaseInsensitiveContains(query) ||
            OffsetGuide.examples(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("選擇拍攝時區").font(.title2.bold())
                    Text("先顯示整點；需要半小時或 15 分鐘時再展開。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.title3).foregroundStyle(.secondary)
                    .accessibilityLabel("關閉時區選擇")
            }

            HStack(spacing: 12) {
                Toggle("顯示 15 分鐘選項", isOn: $state.showQuarterHours)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("showQuarterHourOffsetsToggle")
                Spacer()
                TextField("搜尋 UTC、國家或地區", text: $state.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityIdentifier("offsetSearchField")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(choices) { offset in
                            Button { state.draft = offset } label: {
                                HStack(spacing: 12) {
                                    Text(offset.label)
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                        .frame(width: 100, alignment: .leading)
                                    Text(OffsetGuide.examples(for: offset))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(2)
                                    if state.draft == offset {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(state.draft == offset ? Color.accentColor.opacity(0.17) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(offset.minutes)
                            .accessibilityIdentifier("offsetChoice-\(offset.minutes)")
                        }
                        if choices.isEmpty {
                            Text("找不到符合條件的時區；可開啟 15 分鐘選項或更換關鍵字。")
                                .font(.callout).foregroundStyle(.secondary).padding(24)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 335)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .onAppear { proxy.scrollTo(state.draft.minutes, anchor: .center) }
                .onChange(of: state.showQuarterHours) { _ in
                    if choices.contains(state.draft) { proxy.scrollTo(state.draft.minutes, anchor: .center) }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("目前選取：\(state.draft.label)").font(.headline)
                Text(OffsetGuide.examples(for: state.draft)).font(.callout).textSelection(.enabled)
                Text("代表地區僅供辨識。這是固定 UTC 偏移，不會依城市或拍攝日期自動處理夏令時間；請以拍攝當時實際偏移為準。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("使用 \(state.draft.label)") { onConfirm(state.draft) }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("confirmOffsetButton")
            }
        }
        .padding(22)
        .frame(width: 660)
        .background { AppWindowBackdrop() }
        .onExitCommand(perform: onCancel)
        .accessibilityIdentifier("offsetChooserDialog")
    }
}
