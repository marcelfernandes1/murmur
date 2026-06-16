import AppKit
import SwiftUI

/// Hosts the first-run `OnboardingView` in a chromeless, glass-friendly window
/// (transparent titlebar, full-size content). Shown once on first launch.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let prefs: Preferences
    private let appState: AppState
    private let dictation: DictationController

    init(prefs: Preferences, appState: AppState, dictation: DictationController) {
        self.prefs = prefs
        self.appState = appState
        self.dictation = dictation
    }

    func show() {
        if window == nil {
            let root = OnboardingView(onFinish: { [weak self] in self?.finish() })
                .environment(prefs)
                .environment(appState)
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
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        window?.close()
    }
}
