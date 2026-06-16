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
    let settingsRouter = SettingsRouter()
    private lazy var settingsWindow = SettingsWindowController(
        prefs: preferences,
        appState: appState,
        dictation: dictation,
        vocabulary: vocabulary,
        corrections: corrections,
        router: settingsRouter,
        container: historyStore.container
    )
    private lazy var onboardingWindow = OnboardingWindowController(
        prefs: preferences,
        appState: appState,
        dictation: dictation
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        dictation.bootstrap()

        // First launch: run the welcome flow (permissions + a live practice).
        if !preferences.hasCompletedOnboarding {
            onboardingWindow.show()
            preferences.hasCompletedOnboarding = true
        }
    }

    func showHistory() {
        settingsRouter.category = .history
        settingsWindow.show()
    }

    func showComparison() {
        settingsRouter.category = .comparison
        settingsWindow.show()
    }

    func showSettings() {
        settingsWindow.show()
    }
}
