import SwiftUI
import AppKit
import KeyboardShortcuts

/// A one-key shortcut recorder. The KeyboardShortcuts library's built-in
/// `Recorder` refuses modifier-less keys (it beeps), but the underlying engine
/// registers them fine — so we capture a single keypress ourselves and set the
/// shortcut programmatically. The captured key becomes a global hotkey, which the
/// system consumes (it won't type), so it should be a key you don't otherwise
/// use — a function key is ideal.
struct SingleKeyRecorder: View {
    let name: KeyboardShortcuts.Name
    var onChange: () -> Void = {}

    @State private var capturing = false
    @State private var monitor: Any?
    @State private var display = ""

    var body: some View {
        HStack(spacing: 8) {
            Button(buttonTitle) { capturing ? cancel() : startCapture() }
            if !display.isEmpty && !capturing {
                Button {
                    KeyboardShortcuts.setShortcut(nil, for: name)
                    refresh()
                    onChange()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear single-key trigger")
            }
        }
        .onAppear(perform: refresh)
        .onDisappear(perform: cancel)
    }

    private var buttonTitle: String {
        if capturing { return "Press a key…  (Esc to cancel)" }
        return display.isEmpty ? "Record single key" : display
    }

    private func refresh() {
        display = KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
    }

    private func startCapture() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Escape cancels without binding
                cancel()
                return nil
            }
            // A lone keypress yields a modifier-less Shortcut the library's own
            // Recorder would reject — but setShortcut registers it just fine.
            if let shortcut = KeyboardShortcuts.Shortcut(event: event) {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
                onChange()
            }
            cancel()
            return nil // swallow the key so it doesn't leak into the Settings UI
        }
    }

    private func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
        refresh()
    }
}
