import AppKit
import SwiftUI

/// Both images share one viewport and one pixel transform. Only the clip
/// boundary changes, so dragging the divider cannot change alignment.
struct CompressionComparison: View {
    @ObservedObject var model: CompressionModel
    @Environment(\.displayScale) private var displayScale
    @StateObject private var state = ComparisonImages()
    private var request: String { "\(model.selected?.source.path ?? "")|\(model.comparisonOutput?.path ?? "")" }
    private var zoom: Binding<Double> {
        Binding(get: { log2(max(0.03125, model.comparisonScale)) },
                set: { model.comparisonScale = pow(2, $0) })
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text("原始與壓縮後比較").font(.headline)
                Spacer()
                Text("縮放").font(.caption)
                Slider(value: zoom, in: -5...4).frame(width: 220)
                    .accessibilityLabel("照片縮放倍率")
                    .accessibilityIdentifier("comparisonZoom")
                Text(String(format: "%.0f%%", model.comparisonScale * 100))
                    .font(.callout.monospacedDigit()).frame(width: 62)
                Button("完成") { model.showingComparison = false }
                    .buttonStyle(.glassProminent).keyboardShortcut(.cancelAction)
            }
            GeometryReader { geometry in
                GlassEffectContainer(spacing: 8) {
                  ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let original = state.original, let output = state.output {
                        ComparisonCanvas(original: original, output: output,
                                         zoom: model.comparisonScale, split: state.split)
                            .accessibilityLabel("原始與輸出影像；拖曳照片或使用滾輪移動檢視位置")
                        divider(in: geometry.size)
                        HStack {
                            Text("原始照片").padding(10).glassEffect()
                            Spacer()
                            Text(model.previewIsActual ? "實際輸出" : "壓縮預覽")
                                .padding(10).glassEffect()
                        }.font(.caption.weight(.semibold))
                            .padding(12).frame(maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    } else if state.loading {
                        ProgressView("讀取原尺寸影像…")
                    } else {
                        ContentUnavailableView("無法顯示原尺寸比較", systemImage: "photo.badge.exclamationmark",
                                               description: Text(state.error))
                    }
                  }
                }
                .coordinateSpace(name: "comparisonViewport")
                .clipShape(.rect(corners: .concentric(minimum: .fixed(24))))
                .onAppear { state.viewport = geometry.size }
                .onChange(of: geometry.size) { _, size in state.viewport = size }
            }
            Text("拖曳中央分隔線比較；拖曳照片或使用滾輪移動位置。100% 為一個影像像素對應一個螢幕像素，最高可放大至 1600%。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 1080, height: 760)
        .containerShape(.rect(cornerRadius: 28))
        .task(id: request) {
            state.original = nil; state.output = nil; state.loading = true
            defer { if !Task.isCancelled { state.loading = false } }
            guard let source = model.selected?.source, let target = model.comparisonOutput else {
                state.error = "請先等待壓縮預覽或實際輸出產生。"; return
            }
            let pair = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    (CompressionImages.comparisonImage(source), CompressionImages.comparisonImage(target))
                }
            }.value
            guard !Task.isCancelled else { return }
            guard let original = pair.0, let output = pair.1 else {
                state.error = "此格式無法由 macOS 解碼，或原尺寸超過比較視窗的安全記憶體範圍。"; return
            }
            guard original.width == output.width, original.height == output.height else {
                state.error = "原始與輸出的顯示尺寸不同，無法可靠對齊像素。"; return
            }
            state.original = original; state.output = output; state.split = 0.5
            model.comparisonScale = min(1, min(state.viewport.width * displayScale / CGFloat(original.width),
                                              state.viewport.height * displayScale / CGFloat(original.height)))
        }
        .onDisappear { state.original = nil; state.output = nil }
    }

    private func divider(in size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2).shadow(color: .black.opacity(0.6), radius: 2)
            Image(systemName: "arrow.left.and.right")
                .font(.callout.weight(.bold)).padding(12)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .frame(width: 44, height: size.height).contentShape(Rectangle())
        .position(x: size.width * state.split, y: size.height / 2)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("comparisonViewport"))
            .onChanged { state.split = min(1, max(0, $0.location.x / max(1, size.width))) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("原始與輸出分隔線")
        .accessibilityValue("左側原始照片 \(Int(state.split * 100))%")
        .accessibilityAdjustableAction { direction in
            state.split = min(1, max(0, state.split + (direction == .increment ? 0.05 : -0.05)))
        }
        .accessibilityIdentifier("comparisonDivider")
    }
}

@MainActor
private final class ComparisonImages: ObservableObject {
    @Published var split = 0.5
    @Published var viewport = CGSize(width: 1000, height: 610)
    @Published var original: CGImage?
    @Published var output: CGImage?
    @Published var loading = true
    @Published var error = ""
}

private struct ComparisonCanvas: NSViewRepresentable {
    let original: CGImage
    let output: CGImage
    let zoom: Double
    let split: Double
    func makeNSView(context: Context) -> PixelComparisonView { PixelComparisonView() }
    func updateNSView(_ view: PixelComparisonView, context: Context) {
        if view.original !== original { view.pan = .zero }
        view.original = original; view.output = output
        view.zoom = zoom; view.split = split
        view.clampPan(); view.needsDisplay = true
    }
}

/// Immediate-mode native drawing avoids building enormous zoomed bitmap
/// layers. ImageIO decodes once; dragging only changes the draw transform.
private final class PixelComparisonView: NSView {
    var original: CGImage?
    var output: CGImage?
    var zoom = 1.0
    var split = 0.5
    var pan = CGPoint.zero
    private var dragStart = CGPoint.zero
    private var startPan = CGPoint.zero
    override var acceptsFirstResponder: Bool { true }
    private var pixelScale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var imageSize: CGSize {
        guard let original else { return .zero }
        return CGSize(width: CGFloat(original.width) * zoom / pixelScale,
                      height: CGFloat(original.height) * zoom / pixelScale)
    }
    func clampPan() {
        let size = imageSize
        let x = max(0, (size.width - bounds.width) / 2)
        let y = max(0, (size.height - bounds.height) / 2)
        pan.x = min(x, max(-x, pan.x)); pan.y = min(y, max(-y, pan.y))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let original, let output, let context = NSGraphicsContext.current?.cgContext else { return }
        clampPan()
        let size = imageSize
        let rect = CGRect(x: (bounds.width - size.width) / 2 + pan.x,
                          y: (bounds.height - size.height) / 2 + pan.y,
                          width: size.width, height: size.height)
        context.interpolationQuality = zoom >= 1 ? .none : .high
        let boundary = bounds.width * split
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: boundary, height: bounds.height))
        context.draw(original, in: rect); context.restoreGState()
        context.saveGState()
        context.clip(to: CGRect(x: boundary, y: 0, width: bounds.width - boundary, height: bounds.height))
        context.draw(output, in: rect); context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil); startPan = pan
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pan = CGPoint(x: startPan.x + point.x - dragStart.x, y: startPan.y + point.y - dragStart.y)
        clampPan(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { NSCursor.pop() }
    override func scrollWheel(with event: NSEvent) {
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        pan.x += event.scrollingDeltaX * factor; pan.y -= event.scrollingDeltaY * factor
        clampPan(); needsDisplay = true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
