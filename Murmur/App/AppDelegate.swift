import AppKit

/// Bootstraps the app at launch: a menu-bar app has no window/onAppear to hang
/// setup off of, so hotkey registration and model preloading happen here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let preferences = Preferences()
    let vocabulary = VocabularyStore()
    let corrections = CorrectionStore()
    let historyStore = HistoryStore()

    private(set) lazy var dictation = DictationController(
        appState: appState,
        history: historyStore,
        preferences: preferences,
        vocabulary: vocabulary,
        corrections: corrections
    )
    private lazy var historyWindow = HistoryWindowController(container: historyStore.container)
    private lazy var comparisonWindow = CleanupComparisonWindowController(container: historyStore.container)
    private lazy var settingsWindow = SettingsWindowController(
        prefs: preferences,
        appState: appState,
        dictation: dictation,
        vocabulary: vocabulary,
        corrections: corrections
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        dictation.bootstrap()

        // First launch: open Settings so the user can grant permissions.
        if !preferences.hasCompletedOnboarding {
            showSettings()
            preferences.hasCompletedOnboarding = true
        }
    }

    func showHistory() {
        historyWindow.show()
    }

    func showComparison() {
        comparisonWindow.show()
    }

    func showSettings() {
        settingsWindow.show()
    }
}
