import SwiftUI

/// The app's one Liquid Glass surface primitive. Use it for the *control /
/// navigation layer* — floating panels, popovers, toolbars, badges, the notch —
/// never for long-form reading content (history text, diffs), which belongs on
/// a solid surface per Apple's guidance.
///
/// Wrapping `.glassEffect` here means the whole app shares one glass recipe; if
/// Apple tweaks the material or we retune tint/shape, it changes in one place.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Radius.lg
    var tint: Color? = nil
    /// Interactive glass reacts to touch/pointer with a subtle flex. Use for
    /// tappable surfaces (buttons, the menu-bar popover header).
    var interactive: Bool = false
    var padding: CGFloat = Spacing.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }

    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// A capsule-shaped glass pill (badges, the non-notch dictation indicator).
struct GlassPill<Content: View>: View {
    var tint: Color? = nil
    var interactive: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .glassEffect(glass, in: .capsule)
    }

    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}
