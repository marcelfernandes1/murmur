import AppKit
import SwiftUI

/// Presents `SettingsView` in a standard window on demand (also used for
/// first-run onboarding). AppKit-hosted so it never auto-opens at launch.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let prefs: Preferences
    private let appState: AppState
    private let dictation: DictationController
    private let vocabulary: VocabularyStore
    private let corrections: CorrectionStore

    init(prefs: Preferences, appState: AppState, dictation: DictationController, vocabulary: VocabularyStore, corrections: CorrectionStore) {
        self.prefs = prefs
        self.appState = appState
        self.dictation = dictation
        self.vocabulary = vocabulary
        self.corrections = corrections
    }

    func show() {
        if window == nil {
            let root = SettingsView()
                .environment(prefs)
                .environment(appState)
                .environment(dictation)
                .environment(vocabulary)
                .environment(corrections)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Murmur Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
