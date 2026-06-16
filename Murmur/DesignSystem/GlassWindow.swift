import SwiftUI
import AppKit

/// Turns an AppKit-hosted SwiftUI window into a translucent Liquid-Glass surface:
/// a transparent, edge-to-edge window backed by a desktop-blurring vibrant
/// material — the same effect as the menu-bar popover, for every window.
///
/// Apply to a window's root view. Remember to clear inner content backgrounds
/// (`.scrollContentBackground(.hidden)` on Lists/Forms) so the glass shows through.
extension View {
    func liquidGlassWindow(_ material: NSVisualEffectView.Material = .sidebar) -> some View {
        background(VisualEffectBackdrop(material: material).ignoresSafeArea())
            .background(GlassWindowConfigurator())
    }
}

/// A `behindWindow` vibrant material — blurs the desktop behind the window and
/// adapts to light/dark.
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Makes the hosting window transparent + edge-to-edge so the backdrop is the only
/// surface (no opaque chrome fighting the glass).
private struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
