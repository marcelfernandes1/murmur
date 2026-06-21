import AppKit
import SwiftUI

/// Outer transparent padding baked into the bubble's SwiftUI root so the capsule's
/// soft shadow isn't clipped by the (clear) window. Shared by the view and the
/// positioning math.
private let controlBarShadowPadding: CGFloat = 14

/// A small floating Liquid-Glass control bubble shown elegantly *below* the notch
/// while a recording is hands-free locked: 🔒 indicator · ✓ Done · 🗑 Trash.
///
/// It lives in its own panel — not the notch — because the notch panel can become
/// key, and clicking a key panel drops the frontmost app's focused text field (so
/// the paste fails). This panel `canBecomeKey == false` + `.nonactivatingPanel`,
/// and its `NSHostingView` accepts the first mouse, so SwiftUI buttons fire on a
/// single click *without* ever taking focus from the field being pasted into.
@MainActor
final class HandsFreeControlBar {
    /// Commit (transcribe + insert) — same as pressing the trigger again.
    var onDone: () -> Void = {}
    /// Discard the recording without transcribing.
    var onCancel: () -> Void = {}

    private let model = ControlBarModel()
    private var panel: NSPanel?
    private var isShown = false

    /// Height of DictationNotchView's row inside the notch (mic + waveform).
    private static let notchContentHeight: CGFloat = 36
    /// Elegant gap between the notch/pill bottom and the bubble.
    private static let gapBelowNotch: CGFloat = 14

    init() {
        model.onDone = { [weak self] in self?.onDone() }
        model.onCancel = { [weak self] in self?.onCancel() }
    }

    // MARK: - Show / hide

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        layout(panel, animatingIn: !isShown)
        isShown = true
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6))
        }, completionHandler: { [weak self] in
            // Runs on the main thread; a newer show() may have re-displayed it.
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: - Building

    private func build() {
        let host = FirstMouseHostingView(rootView: HandsFreeControlBarView(model: model))
        host.layoutSubtreeIfNeeded()

        let bar = NonKeyPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = false // the SwiftUI glass + shadow provide the depth
        bar.level = .screenSaver
        bar.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        bar.ignoresMouseEvents = false
        bar.contentView = host
        bar.setContentSize(host.fittingSize)
        panel = bar
    }

    private func layout(_ panel: NSPanel, animatingIn: Bool) {
        // Use the same screen DynamicNotch shows on (NSScreen.screens[0]).
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let size = panel.frame.size

        // Bottom edge of DynamicNotchKit's expanded content, from the screen top.
        // The real notch and the floating (notchless) pill have DIFFERENT geometry:
        // the floating pill sits ~35pt lower (it adds a 20pt pad + a menubar-height
        // offset + 15pt insets), which is why the bubble overlapped the pill on a
        // non-notched external display. Compute each case.
        let menubarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let hasNotch = screen.safeAreaInsets.top > 0
        let pillBottom: CGFloat = hasNotch
            ? screen.safeAreaInsets.top + Self.notchContentHeight + 15
            : menubarHeight + 20 + Self.notchContentHeight + 30

        let capsuleTopY = screen.frame.maxY - (pillBottom + Self.gapBelowNotch)
        let x = (screen.frame.midX - size.width / 2).rounded()
        // The visible capsule is inset `controlBarShadowPadding` from the window top.
        let y = (capsuleTopY + controlBarShadowPadding - size.height).rounded()

        if animatingIn {
            panel.setFrameOrigin(NSPoint(x: x, y: y + 8))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(NSPoint(x: x, y: y))
            }
        } else {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

// MARK: - Model

@MainActor
@Observable
private final class ControlBarModel {
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}
}

// MARK: - SwiftUI content

private struct HandsFreeControlBarView: View {
    let model: ControlBarModel

    /// One optical size for every glyph so the set reads as proportional. SF Symbols
    /// share a cap height at a given point size, so equal sizes look balanced.
    private let glyphSize: CGFloat = 13

    var body: some View {
        HStack(spacing: 6) {
            // Lock is a status indicator (dimmer), not a button.
            Image(systemName: "lock.fill")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            GlyphButton(symbol: "checkmark", size: glyphSize + 1,
                        tint: Palette.success, hoverTint: Palette.success,
                        action: model.onDone)
                .accessibilityLabel("Insert dictation now")

            GlyphButton(symbol: "trash", size: glyphSize,
                        tint: .primary, hoverTint: Palette.danger,
                        action: model.onCancel)
                .accessibilityLabel("Discard recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.clear, in: .capsule)
        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
        .padding(controlBarShadowPadding) // room so the shadow isn't clipped
    }
}

/// A glyph-only button — no background fill, so the bubble stays completely clear.
/// The whole frame is the hit target; hover scales the glyph and shifts its tint.
private struct GlyphButton: View {
    let symbol: String
    var size: CGFloat
    var tint: Color
    var hoverTint: Color
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovering ? hoverTint : tint)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
                .scaleEffect(reduceMotion ? 1 : (hovering ? 1.12 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: hovering)
    }
}

// MARK: - AppKit hosting

/// A panel that receives clicks but never becomes key/main — so interacting with it
/// can't move keyboard focus away from the user's frontmost text field.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI bubble and accepts the first mouse, so its buttons fire on a
/// single click even though the panel is never key. (SwiftUI routes all of the
/// content's mouse events through this one hosting view, so the override suffices.)
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
