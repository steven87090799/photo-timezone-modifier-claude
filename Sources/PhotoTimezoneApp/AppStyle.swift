import AppKit
import SwiftUI

/// Shared native surfaces. Respect the system's accessibility setting instead
/// of simulating glass with custom blur, gradients or always-running effects.
private struct AppGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor),
                               in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.glassEffect(.regular, in: .rect(corners: .concentric(minimum: .fixed(radius))))
        }
    }
}

extension View {
    func appGlass(cornerRadius: CGFloat = 24) -> some View {
        modifier(AppGlassSurface(radius: cornerRadius))
    }

    func appContentSurface(cornerRadius: CGFloat = 14) -> some View {
        background(.background.opacity(0.18), in: .rect(corners: .concentric(minimum: .fixed(cornerRadius))))
            .clipShape(.rect(corners: .concentric(minimum: .fixed(cornerRadius))))
    }
}

/// Shared import control: identical wording, hit area and drop feedback in
/// both workflows. Native glass supplies the pointer response and contrast.
struct PhotoImportArea: View {
    let targeted: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.title2)
                Text("拖入相片或資料夾").font(.callout.weight(.medium))
                Text("或按一下選取多個項目").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.tint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct AppWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// File dialogs belong to the document window and cannot stack when a button
/// is activated twice before AppKit has finished presenting the first panel.
@MainActor
enum AppFilePanels {
    private static var activePanel: NSSavePanel?

    static func present(_ panel: NSSavePanel, asSheet: Bool = true, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard activePanel == nil else {
            activePanel?.makeKeyAndOrderFront(nil)
            return
        }
        activePanel = panel
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            activePanel = nil
            completion(response)
        }
        if asSheet, let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
