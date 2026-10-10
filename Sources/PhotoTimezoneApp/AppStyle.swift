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
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

extension View {
    func appGlass(cornerRadius: CGFloat = 18) -> some View {
        modifier(AppGlassSurface(radius: cornerRadius))
    }

    func appContentSurface(cornerRadius: CGFloat = 14) -> some View {
        background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
