import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictation = Self("dictation")
    static let dictation2 = Self("dictation2")
    static let dictation3 = Self("dictation3")
    /// A single-key (modifier-less) trigger, set via `SingleKeyRecorder` since the
    /// library's own Recorder UI refuses modifier-less keys.
    static let dictationSingle = Self("dictationSingle")
}

/// Push-to-talk triggers: the Fn / 🌐 key (toggleable) plus up to three custom
/// shortcuts. Any of them starts/stops a dictation. The Fn key can't be a normal
/// hotkey (it's a modifier), so it's watched via `flagsChanged`.
@MainActor
final class HotkeyManager {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    static let shortcutNames: [KeyboardShortcuts.Name] = [.dictation, .dictation2, .dictation3, .dictationSingle]

    private var fnEnabled = false
    private var fnDown = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var handlersBound = false

    /// kVK_Function — the Fn / Globe key.
    private static let fnKeyCode: UInt16 = 0x3F

    /// Bind the custom-shortcut handlers once, then apply the Fn setting.
    func start(fnEnabled: Bool) {
        if !handlersBound {
            for name in Self.shortcutNames {
                KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.onPress() }
                KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.onRelease() }
            }
            handlersBound = true
        }
        setFnEnabled(fnEnabled)
    }

    func setFnEnabled(_ enabled: Bool) {
        removeFnMonitors()
        fnEnabled = enabled
        if enabled { addFnMonitors() }
    }

    var triggersDescription: String {
        var parts: [String] = []
        if fnEnabled { parts.append("🌐 Fn") }
        for name in Self.shortcutNames {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
                parts.append(shortcut.description)
            }
        }
        return parts.isEmpty ? "none set" : parts.joined(separator: " / ")
    }

    // MARK: - Fn / Globe key

    private func addFnMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func removeFnMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        fnDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        let isDown = event.modifierFlags.contains(.function)
        if isDown, !fnDown {
            fnDown = true
            onPress()
        } else if !isDown, fnDown {
            fnDown = false
            onRelease()
        }
    }
}
