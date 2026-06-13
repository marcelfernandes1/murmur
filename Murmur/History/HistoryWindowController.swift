import AppKit
import SwiftUI
import SwiftData

/// Presents `HistoryView` in a standard window on demand. Using an AppKit window
/// (rather than a SwiftUI `Window` scene) keeps it from auto-opening at launch,
/// which matters for a menu-bar-only app.
@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func show() {
        if window == nil {
            let root = HistoryView().modelContainer(container)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Murmur History"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 420, height: 540))
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
