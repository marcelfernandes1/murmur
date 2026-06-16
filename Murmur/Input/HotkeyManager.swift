import AppKit
import KeyboardShortcuts
import OSLog

extension KeyboardShortcuts.Name {
    static let dictation = Self("dictation")
    static let dictation2 = Self("dictation2")
    static let dictation3 = Self("dictation3")
    /// A single-key (modifier-less) trigger, set via `SingleKeyRecorder` since the
    /// library's own Recorder UI refuses modifier-less keys.
    static let dictationSingle = Self("dictationSingle")
}

/// Thread-safe mirror of "does the trigger key appear to be held". Read from the
/// audio lifecycle queue (config-change diagnostics) while written on the main
/// actor, so it carries its own lock.
final class HotkeyHeldState: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    func set(_ value: Bool) { lock.lock(); held = value; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return held }
}

/// Push-to-talk triggers: the Fn / 🌐 key (toggleable) plus up to three custom
/// shortcuts. Any of them starts/stops a dictation. The Fn key can't be a normal
/// hotkey (it's a modifier), so it's watched via `flagsChanged`.
@MainActor
final class HotkeyManager {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    /// Thread-safe view of whether the trigger is currently held (read by the audio
    /// recorder's configuration-change diagnostics from another queue).
    let heldState = HotkeyHeldState()

    static let shortcutNames: [KeyboardShortcuts.Name] = [.dictation, .dictation2, .dictation3, .dictationSingle]

    private static let log = Logger(subsystem: "com.murmur.app", category: "hotkey")

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
                KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                    self?.heldState.set(true)
                    self?.onPress()
                }
                KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                    self?.heldState.set(false)
                    self?.onRelease()
                }
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
        heldState.set(false)
    }

    /// Single deduplicated handler for BOTH the global and local flagsChanged
    /// monitors. The Fn/Globe key arrives as keyCode 63 with `.function` true on
    /// press and false on release. We commit `fnDown` DIRECTLY from the event's
    /// `.function` bit — never a guarded toggle, which a duplicate or out-of-order
    /// delivery could leave stuck (that bug made the release never register) — and
    /// fire onPress/onRelease only on a real transition.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        let isDown = event.modifierFlags.contains(.function)
        let wasDown = fnDown
        fnDown = isDown
        heldState.set(isDown)
        if isDown, !wasDown {
            Self.log.log("Fn down → onPress")
            onPress()
        } else if !isDown, wasDown {
            Self.log.log("Fn up → onRelease")
            onRelease()
        }
    }
}
