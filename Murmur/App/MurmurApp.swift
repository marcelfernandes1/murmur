import SwiftUI
import AppKit

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Murmur", systemImage: "waveform") {
            MenuBarContent(
                showHistory: { delegate.showHistory() },
                showComparison: { delegate.showComparison() },
                showSettings: { delegate.showSettings() }
            )
            .environment(delegate.appState)
            .environment(delegate.dictation)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Contents of the menu-bar dropdown. History, Settings, and live status get
/// expanded here in later phases.
private struct MenuBarContent: View {
    let showHistory: () -> Void
    let showComparison: () -> Void
    let showSettings: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(DictationController.self) private var dictation

    var body: some View {
        Text("Murmur \(appState.versionString)")
            .font(.headline)

        Divider()

        Text(statusLabel)
        if !appState.shortcutHint.isEmpty {
            Text(appState.shortcutHint)
        }
        if let modelLabel {
            Text(modelLabel)
        }

        if !appState.accessibilityEnabled {
            Button("⚠️ Enable Accessibility to type into apps…") {
                dictation.enableAccessibility()
            }
        }

        if let learned = appState.recentlyLearned {
            Button("Undo learned “\(learned.corrected)”") {
                dictation.undoLastLearned()
            }
        }

        Divider()

        Button("History…") { showHistory() }
        Button("Cleanup Comparison…") { showComparison() }
        Button("Settings…") { showSettings() }
            .keyboardShortcut(",")

        if !appState.lastTranscript.isEmpty {
            Text("Last: \(appState.lastTranscript)")
        }

        Divider()

        Button("Quit Murmur") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLabel: String {
        switch appState.status {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .error(let message): return "Error: \(message)"
        }
    }

    private var modelLabel: String? {
        switch appState.modelPhase {
        case .idle, .ready: return nil
        case .preparing: return "Model: downloading/loading…"
        case .failed: return "Model: failed to load"
        }
    }
}
