import AppKit
import OSLog

/// Lets the user "lock" a push-to-talk recording into hands-free mode: while the
/// trigger is held, pressing **Space** flips the recording into a locked state so
/// the trigger can be released and recording continues. A later trigger press then
/// commits + inserts.
///
/// Implemented as an active `CGEventTap` (needs Accessibility — which Murmur
/// already requires for pasting) so the Space that performs the lock is *consumed*
/// and never leaks into the focused app. The tap is created only when a recording
/// begins and torn down when it commits, so Murmur isn't watching the keyboard
/// outside an active dictation.
///
/// The tap is attached to the **main** run loop, so its callback runs on the main
/// thread — every property here is therefore main-thread-only (the C trampoline
/// re-enters the main actor via `assumeIsolated`).
@MainActor
final class SpaceLockMonitor {
    /// Invoked (on the main actor) when Space locks the active recording.
    var onLock: () -> Void = {}
    /// Invoked (on the main actor) when Esc cancels the active recording.
    var onCancel: () -> Void = {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Whether the next Space should lock + be consumed. True only during the
    /// initial held window; cleared the instant a lock fires (so a second fast
    /// Space passes through) and when the recording stops.
    private var armed = false

    private static let spaceKeyCode: Int64 = 49 // kVK_Space
    private static let escapeKeyCode: Int64 = 53 // kVK_Escape
    private static let log = Logger(subsystem: "com.murmur.app", category: "hotkey")

    /// Begin watching for the lock Space. Creates the tap on first use; idempotent.
    /// Returns whether the tap is active — `false` means Accessibility isn't granted,
    /// so the hands-free Space/Esc gestures won't work and the caller can react.
    @discardableResult
    func start() -> Bool {
        armed = true
        guard tap == nil else { return true }

        // Only keyDown is requested. tapDisabledByTimeout/ByUserInput are special
        // high-rawValue notifications the system always delivers — never OR them
        // into the mask.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,            // active tap → may consume events
            eventsOfInterest: mask,
            callback: spaceLockCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.log.error("SpaceLockMonitor: tap creation failed — Accessibility not granted?")
            armed = false
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    /// Stop watching and tear the tap down. Idempotent.
    func stop() {
        armed = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    /// Called from the C trampoline on the main run loop. Returns nil to consume.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // A slow callback (beachball) — or user input — makes the system disable the
        // tap; re-enable so hands-free keeps working for the rest of the recording.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // A bare Esc discards the in-flight recording (same as the Trash button),
        // consumed so it doesn't also reach the focused app. A *modified* Esc
        // (⌘⎋ force-quit, ⌃⎋, ⌥⎋, ⇧⎋) belongs to the system / focused app — pass it
        // through untouched rather than swallowing it for the whole recording.
        if keyCode == Self.escapeKeyCode {
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            if event.flags.intersection(modifiers).isEmpty {
                onCancel()
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Space (while armed) locks into hands-free. Disarm first so a second quick
        // Space isn't swallowed too; afterwards Spaces pass through until stop.
        if keyCode == Self.spaceKeyCode, armed {
            armed = false
            onLock()
            return nil // consume the lock Space so it never reaches the focused app
        }

        return Unmanaged.passUnretained(event)
    }
}

/// Top-level C-compatible trampoline — a `CGEventTapCallBack` must be a
/// non-capturing function. The tap runs on the main run loop, so re-entering the
/// main actor via `assumeIsolated` is safe (not a thread hop).
private func spaceLockCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<SpaceLockMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { monitor.handle(type, event) }
}
