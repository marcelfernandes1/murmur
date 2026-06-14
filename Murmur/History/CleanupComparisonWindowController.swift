import AppKit
import SwiftUI
import SwiftData

/// Presents `CleanupComparisonView` in a standard on-demand window (AppKit, so it
/// doesn't auto-open at launch in this menu-bar-only app).
@MainActor
final class CleanupComparisonWindowController {
    private var window: NSWindow?
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func show() {
        if window == nil {
            let root = CleanupComparisonView().modelContainer(container)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Cleanup Comparison"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 520, height: 600))
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
