import AppKit
import SwiftUI

/// Hosts `WhatsNewView` in the same chromeless glass window onboarding uses, so
/// an update feels like part of the app rather than a system alert.
@MainActor
final class WhatsNewWindowController {
    private var window: NSWindow?
    private let prefs: Preferences
    private let dictation: DictationController

    init(prefs: Preferences, dictation: DictationController) {
        self.prefs = prefs
        self.dictation = dictation
    }

    func show(releases: [ReleaseNotes.Release]) {
        guard !releases.isEmpty else { return }
        if window == nil {
            let root = WhatsNewView(releases: releases, onFinish: { [weak self] in self?.finish() })
                .environment(prefs)
                .environment(dictation)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.styleMask = [.titled, .closable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        // Murmur is an LSUIElement (menu-bar) app, and for those `activate` does
        // NOT lift a window above the frontmost application — the update notes
        // opened silently behind whatever the user was working in, which is the
        // same as not showing them at all. `orderFrontRegardless` is the part
        // that actually raises it.
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        window?.close()
    }
}
