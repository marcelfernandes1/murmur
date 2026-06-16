import AppKit
import SwiftUI
import SwiftData

/// Presents `SettingsView` in a window on demand. Also the host for History and
/// the Cleanup Comparison (now Settings categories), so it carries the SwiftData
/// container and a `SettingsRouter` for deep-linking from the menu bar.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let prefs: Preferences
    private let appState: AppState
    private let dictation: DictationController
    private let vocabulary: VocabularyStore
    private let corrections: CorrectionStore
    private let router: SettingsRouter
    private let container: ModelContainer

    init(prefs: Preferences, appState: AppState, dictation: DictationController,
         vocabulary: VocabularyStore, corrections: CorrectionStore,
         router: SettingsRouter, container: ModelContainer) {
        self.prefs = prefs
        self.appState = appState
        self.dictation = dictation
        self.vocabulary = vocabulary
        self.corrections = corrections
        self.router = router
        self.container = container
    }

    func show() {
        if window == nil {
            let root = SettingsView()
                .environment(prefs)
                .environment(appState)
                .environment(dictation)
                .environment(vocabulary)
                .environment(corrections)
                .environment(router)
                .modelContainer(container)
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
