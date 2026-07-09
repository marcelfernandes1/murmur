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
    /// Bumped on every `show()`. A `hide()`'s fade-out captures the value live at the
    /// time it starts; if a newer `show()` has run by the time the fade completes, the
    /// generations differ and the stale completion is skipped — so a quick lock right
    /// after a commit can never order the just-revealed bubble back out.
    private var showGeneration = 0
    private var spaceObserver: NSObjectProtocol?
    /// Fires once a second while the bubble should be up; rescues it if it isn't.
    private var watchdog: Timer?

    /// Height of DictationNotchView's row inside the notch (mic + waveform).
    private static let notchContentHeight: CGFloat = 36
    /// Elegant gap between the notch/pill bottom and the bubble.
    private static let gapBelowNotch: CGFloat = 14
    /// Show on every Space (desktop), stay put during Exposé, and remain visible
    /// over fullscreen apps — the same recipe as the notch panel.
    private static let allSpacesBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    init() {
        model.onDone = { [weak self] in self?.onDone() }
        model.onCancel = { [weak self] in self?.onCancel() }
        // Despite `.canJoinAllSpaces`, a panel that survives across desktops can end
        // up pinned to the Space it was last shown on — switch Spaces mid-lock and the
        // bubble is gone (while the notch, whose window is rebuilt every dictation,
        // follows fine). v0.4.44 tried rescuing the pinned panel in place (re-apply
        // the behavior + orderFrontRegardless); that worked in a clean-room repro but
        // NOT in the field. So do what makes the notch immune: replace the panel with
        // a freshly built one, which has no Space affinity by construction. Gated on
        // `isShown`, so it can never resurrect a bubble that hide() dismissed.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.presentFreshPanel(animated: false)
            }
        }
    }

    deinit {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        watchdog?.invalidate()
    }

    // MARK: - Show / hide

    func show() {
        showGeneration &+= 1
        // Always a brand-new panel: reusing one across desktops is what let the window
        // server pin the bubble to a stale Space in the first place. `animated` only
        // chooses the *entrance* (slide+fade for a fresh lock vs. instantly up when
        // re-presenting an already-shown bubble).
        presentFreshPanel(animated: !isShown)
        isShown = true
        startWatchdog()
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        stopWatchdog()
        let generation = showGeneration
        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6))
        }, completionHandler: { [weak self] in
            // Runs on the main thread; a newer show() may have replaced the panel (it
            // orders this one out itself). Skip unless this fade is still the current
            // story: the visible flag stayed off and no newer show() ran.
            MainActor.assumeIsolated {
                guard let self, !self.isShown, self.showGeneration == generation else { return }
                panel.orderOut(nil)
                if self.panel === panel { self.panel = nil }
            }
        })
    }

    // MARK: - Building

    /// Build a fresh panel and put it on screen, replacing (and ordering out) any
    /// existing one. A new window has no window-server Space affinity, so unlike the
    /// v0.4.44 in-place rescue this cannot leave the bubble stranded on another desktop.
    private func presentFreshPanel(animated: Bool) {
        let old = panel
        old?.orderOut(nil)

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
        bar.collectionBehavior = Self.allSpacesBehavior
        // NSPanel hides itself on app deactivation by default — an overlay that must
        // stay up while the user works in *other* apps can never want that.
        bar.hidesOnDeactivate = false
        // We keep strong references and never call close(); without this, a stray
        // close would over-release the ARC-owned panel.
        bar.isReleasedWhenClosed = false
        bar.ignoresMouseEvents = false
        bar.contentView = host
        bar.setContentSize(host.fittingSize)
        panel = bar
        layout(bar, animatingIn: animated)
    }

    // MARK: - Watchdog

    /// The Space-change observer is the primary rescue, but it only helps when the
    /// notification actually arrives. Once a second while the bubble should be up,
    /// verify it truly is on the active desktop (`occlusionState`) and rebuild if not
    /// — so no unreproduced failure mode can strand the bubble for more than ~1s.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown, let panel = self.panel else { return }
                if !panel.occlusionState.contains(.visible) {
                    self.presentFreshPanel(animated: false)
                }
            }
        }
        // .common keeps the check firing while menus / drags spin the run loop.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
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
            // Already shown: reposition, and defensively reassert visibility (alpha +
            // front order) so this path can never leave the bubble stuck invisible.
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 1
            panel.orderFrontRegardless()
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
