import ApplicationServices
import AppKit

/// After we paste a transcript into another app's text field, this watches that
/// field (via the Accessibility API) for the user correcting a word, and reports
/// the change so it can be learned.
///
/// It polls the focused element's value rather than relying on
/// `kAXValueChangedNotification`, which many apps (Electron, web fields) emit
/// unreliably. Polling a single element for a bounded window is cheap and works
/// across far more apps. If the field's value can't be read at all, learning is
/// simply skipped for that dictation.
@MainActor
final class FieldEditWatcher {
    /// Observed word edit; the controller checks negative evidence before learning.
    var onEdit: ((CorrectionDetector.Candidate, [CorrectionStore.AppliedCorrection]) -> Bool)?

    private var element: AXUIElement?
    private var baseline = ""
    private var insertedRange: NSRange?
    private var pollTask: Task<Void, Never>?

    struct Access {
        var focused: () -> AXUIElement?
        var value: (AXUIElement) -> String?
        var selection: (AXUIElement) -> NSRange?
    }

    struct Timing {
        var settleDelay: Duration = .milliseconds(350)
        var pollInterval: Duration = .milliseconds(550)
        var maxTicks = 55 // ~30 seconds
        var editSettleDuration: Duration = .seconds(3)
    }

    private let access: Access
    private let timing: Timing

    init(access: Access? = nil, timing: Timing = Timing()) {
        self.access = access ?? Access(focused: Self.focusedElement,
                                       value: Self.stringValue, selection: Self.selectedRange)
        self.timing = timing
    }

    /// Begin watching the currently-focused field for an edit to `insertedText`.
    func start(insertedText: String, pastedInto: AXUIElement? = nil, applied: [CorrectionStore.AppliedCorrection] = []) {
        cancel()
        Self.diagReset()
        guard let target = pastedInto ?? access.focused(), let beforePaste = access.value(target),
              (beforePaste as NSString).length <= CorrectionDetector.maxTextLength else { return }
        let selection = access.selection(target)
        Self.diag("start: watching for edit, insertedLen=\(insertedText.count)")
        let settle = timing.settleDelay
        let interval = timing.pollInterval
        let maxTicks = timing.maxTicks
        // Number of consecutive unchanged polls required before an edit is
        // considered settled (rounded up so we always cover editSettleDuration).
        let requiredStableTicks = max(
            1, Int((Self.seconds(timing.editSettleDuration) / Self.seconds(interval)).rounded(.up)))
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard let self, !Task.isCancelled else { Self.diag("aborted before snapshot"); return }
            guard let focused = self.access.focused(), CFEqual(target, focused),
                  let value = self.access.value(target),
                  let range = CorrectionDetector.insertionRange(
                    text: insertedText, before: beforePaste, after: value, selection: selection) else {
                Self.diag("paste could not be verified in the original field; learning skipped")
                self.cancel()
                return
            }
            self.element = target
            self.baseline = value
            self.insertedRange = range
            Self.diag("snapshot ok: baselineLen=\(value.count)")

            var lastValue = self.baseline
            var stableTicks = 0
            var ticks = 0
            while !Task.isCancelled, ticks < maxTicks, let el = self.element {
                try? await Task.sleep(for: interval)
                ticks += 1
                guard !Task.isCancelled else { break }
                guard let focused = self.access.focused(), CFEqual(el, focused),
                      let current = self.access.value(el),
                      (current as NSString).length <= CorrectionDetector.maxTextLength else { break }
                if current == self.baseline {
                    lastValue = current
                    stableTicks = 0
                    continue
                }
                // Wait for the edit to settle before judging it: the value must
                // stay unchanged for editSettleDuration (requiredStableTicks
                // consecutive polls). A brief mid-edit pause resets the counter,
                // so we don't learn from a half-finished correction.
                if current == lastValue {
                    stableTicks += 1
                    if stableTicks >= requiredStableTicks {
                        let candidate = CorrectionDetector.edit(
                            before: self.baseline, after: current, insertedRange: self.insertedRange)
                        if let candidate {
                            Self.diag("word edit found after \(stableTicks) stable ticks")
                            if self.onEdit?(candidate, applied) == true {
                                self.cancel()
                                return
                            }
                        } else {
                            Self.diag("edit settled but no single-word edit within insertion")
                        }
                    }
                } else {
                    stableTicks = 0
                }
                lastValue = current
            }
            // A cancelled older task must never tear down a newer watch session.
            guard !Task.isCancelled else { return }
            Self.diag("watch window ended after \(ticks) ticks with no learnable edit")
            self.cancel()
        }
    }

    // MARK: - Diagnostics (DEBUG-only)
    // Metadata only: never log transcript or surrounding field contents.
    // Compiled out entirely in release.
    #if DEBUG
    private static let diagURL = URL(fileURLWithPath: "/tmp/murmur_learn.log")
    #endif
    static func diagReset() {
        #if DEBUG
        try? Data().write(to: diagURL)
        #endif
    }
    static func diag(_ message: String) {
        #if DEBUG
        guard let data = ("LEARN " + message + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: diagURL) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: diagURL)
        }
        #endif
    }

    /// Stop watching (called when a new dictation starts or a correction lands).
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        element = nil
    }

    /// A `Duration` as a `Double` count of seconds (used to size the poll loop).
    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    // MARK: - AX reads

    private static func focusedElement() -> AXUIElement? {
        var roots = [AXUIElementCreateSystemWide()]
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            roots.append(AXUIElementCreateApplication(pid))
        }
        for root in roots {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
               let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
