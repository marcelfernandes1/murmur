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
    /// Invoked on the main actor when a validated correction is detected.
    var onCorrection: ((CorrectionDetector.Candidate) -> Void)?

    private var element: AXUIElement?
    private var baseline = ""
    private var insertedRange: NSRange?
    private var pollTask: Task<Void, Never>?

    private let settleDelay: Duration = .milliseconds(350)   // let the synthetic ⌘V land first
    private let pollInterval: Duration = .milliseconds(550)
    private let maxTicks = 55                                 // ~30s watch window, then give up

    /// Begin watching the currently-focused field for an edit to `insertedText`.
    func start(insertedText: String) {
        cancel()
        Self.diagReset()
        Self.diag("start: watching for edit, insertedLen=\(insertedText.count) text=“\(insertedText.prefix(60))”")
        let settle = settleDelay
        let interval = pollInterval
        let maxTicks = maxTicks
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard let self, !Task.isCancelled else { Self.diag("aborted before snapshot"); return }
            guard self.snapshot(insertedText: insertedText) else {
                Self.diag("snapshot FAILED — no focused element or value unreadable via AX (app doesn't expose text). Learning skipped.")
                return
            }
            Self.diag("snapshot ok: baselineLen=\(self.baseline.count) insertedRange=\(self.insertedRange.map { "\($0)" } ?? "nil") baseline=“\(self.baseline.prefix(80))”")

            var lastValue = self.baseline
            var ticks = 0
            while !Task.isCancelled, ticks < maxTicks, let el = self.element {
                try? await Task.sleep(for: interval)
                ticks += 1
                guard !Task.isCancelled else { break }
                guard let current = Self.stringValue(of: el) else { Self.diag("value unreadable at tick \(ticks) — stopping"); break }
                if current == self.baseline {
                    lastValue = current
                    continue
                }
                // Wait for typing to settle (value unchanged across one interval)
                // before judging it — otherwise we'd diff a half-typed word.
                if current == lastValue {
                    let candidate = CorrectionDetector.candidate(
                        before: self.baseline, after: current, insertedRange: self.insertedRange)
                    if let candidate {
                        Self.diag("CANDIDATE found: “\(candidate.heard)” → “\(candidate.corrected)”")
                        self.onCorrection?(candidate)
                        self.cancel()
                        return
                    } else {
                        Self.diag("edit settled but NO candidate. before=“\(self.baseline.prefix(80))” after=“\(current.prefix(80))” range=\(self.insertedRange.map { "\($0)" } ?? "nil")")
                    }
                }
                lastValue = current
            }
            Self.diag("watch window ended after \(ticks) ticks with no learnable edit")
            self.cancel()
        }
    }

    // MARK: - TEMP diagnostics (remove once edit-learning is confirmed working)
    private static let diagURL = URL(fileURLWithPath: "/tmp/murmur_learn.log")
    static func diagReset() { try? Data().write(to: diagURL) }
    static func diag(_ message: String) {
        guard let data = ("LEARN " + message + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: diagURL) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: diagURL)
        }
    }

    /// Stop watching (called when a new dictation starts or a correction lands).
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        element = nil
    }

    // MARK: - Snapshot

    /// Capture the focused element and its post-paste value/insertion point.
    /// Returns false if there's nothing readable to watch.
    private func snapshot(insertedText: String) -> Bool {
        guard let el = Self.focusedElement(), let value = Self.stringValue(of: el) else { return false }
        guard value.count <= 20_000 else { return false }   // don't diff huge documents
        element = el
        baseline = value
        insertedRange = Self.locateInsertion(of: insertedText, in: value, caret: Self.selectedRange(of: el))
        return true
    }

    /// Work out where our text landed: the caret sits at the end of a paste, so
    /// the inserted span is the `insertedText`-length run ending there. Fall back
    /// to the last literal occurrence if the caret isn't available.
    private static func locateInsertion(of insertedText: String, in value: String, caret: NSRange?) -> NSRange? {
        let ns = value as NSString
        let length = (insertedText as NSString).length
        if let caret, caret.location != NSNotFound {
            let end = caret.location + caret.length
            let start = end - length
            if start >= 0, end <= ns.length {
                let range = NSRange(location: start, length: length)
                if ns.substring(with: range).caseInsensitiveCompare(insertedText) == .orderedSame {
                    return range
                }
            }
        }
        let found = ns.range(of: insertedText, options: .backwards)
        return found.location == NSNotFound ? nil : found
    }

    // MARK: - AX reads

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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
