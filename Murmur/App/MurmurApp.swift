import SwiftUI
import AppKit

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(
                showHistory: { delegate.showHistory() },
                showComparison: { delegate.showComparison() },
                showSettings: { delegate.showSettings() }
            )
            .environment(delegate.appState)
            .environment(delegate.dictation)
            .environment(delegate.preferences)
            .environmentObject(delegate.updater)
        } label: {
            MenuBarLabel(appState: delegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}
