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
    private var fnTap: CFMachPort?
    private var fnTapSource: CFRunLoopSource?
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
        // PRIMARY: a CGEventTap placed as early in the event pipeline as possible —
        // HID level, head-inserted — so we observe the Fn key BEFORE other apps'
        // session-level taps. On a machine whose pipeline is polluted by leaked/slow
        // taps (e.g. Logitech Options+, Siri), an NSEvent global monitor is delivered
        // *downstream* of all of them and can arrive ~1 s late; a head-inserted HID tap
        // is immune. Listen-only — we never modify or consume the event.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            guard let tap = CGEvent.tapCreate(
                tap: location, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: fnTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { continue }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            fnTap = tap
            fnTapSource = source
            Self.log.log("Fn via CGEventTap (\(location == .cghidEventTap ? "HID" : "session"))")
            break
        }

        // SAFETY NET: also keep the NSEvent monitors. Both paths feed the SAME
        // transition-guarded state machine (`commitFn`), which is idempotent — so the
        // fast tap fires first and the later NSEvent delivery is a no-op (no double
        // trigger). If the tap couldn't be created at all (no permission), NSEvent
        // alone still drives, preserving the old behavior.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func removeFnMonitors() {
        if let fnTap {
            CGEvent.tapEnable(tap: fnTap, enable: false)
            CFMachPortInvalidate(fnTap)
        }
        if let fnTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), fnTapSource, .commonModes)
        }
        fnTap = nil
        fnTapSource = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        fnDown = false
        heldState.set(false)
    }

    /// Commit the Fn key state from whichever source saw it first. We set `fnDown`
    /// DIRECTLY from the event bit (never a guarded toggle, which a duplicate or
    /// out-of-order delivery could wedge) and fire onPress/onRelease ONLY on a real
    /// transition — which also makes the tap + NSEvent co-drivers idempotent.
    private func commitFn(isDown: Bool) {
        let wasDown = fnDown
        guard isDown != wasDown else { return }
        fnDown = isDown
        heldState.set(isDown)
        if isDown { onPress() } else { onRelease() }
    }

    /// NSEvent flagsChanged (safety-net path). Fn/Globe arrives as keyCode 63 with
    /// `.function` set on press, clear on release.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        commitFn(isDown: event.modifierFlags.contains(.function))
    }

    /// CGEventTap flagsChanged (primary, low-latency path). Runs on the main run loop.
    fileprivate func handleFnTap(_ type: CGEventType, _ event: CGEvent) {
        // A slow callback or user input can make the system disable the tap; re-enable
        // so Fn keeps working for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let fnTap { CGEvent.tapEnable(tap: fnTap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(Self.fnKeyCode) else { return }
        commitFn(isDown: event.flags.contains(.maskSecondaryFn))
    }
}

/// Top-level C-compatible trampoline for the Fn CGEventTap (a `CGEventTapCallBack`
/// must be non-capturing). The tap is on the main run loop, so re-entering the main
/// actor via `assumeIsolated` is a no-op hop, not a thread switch. Always returns the
/// event unmodified (listen-only).
private func fnTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { manager.handleFnTap(type, event) }
    return Unmanaged.passUnretained(event)
}
