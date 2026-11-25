import ApplicationServices
import AppKit
import Carbon.HIToolbox
import IOKit

/// Wraps the Accessibility (AX) APIs we need: permission state, detecting
/// whether the focused UI element accepts text, and the secure-input guard.
@MainActor
final class AccessibilityManager {
    /// Whether the app is trusted for Accessibility (required to read the
    /// focused element and to post synthetic key events).
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// True when SOME process on this Mac has secure keyboard input switched on.
    ///
    /// This is system-wide, not "the focused field is a password field": a `sudo`
    /// prompt left waiting in a background terminal tab, a password manager, a
    /// browser window with a login form, or an app that simply forgot to switch
    /// it off all hold it while the user types somewhere else entirely. Never
    /// decide a delivery on this alone — use `secureFieldVerdict()`.
    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// How a delivery must treat the field that currently has focus.
    enum SecureFieldVerdict: Equatable {
        /// Nothing secret about it. Insert (or copy) and record as usual.
        case normal
        /// The frontmost app holds secure input but the focused field is an
        /// ordinary one — a terminal with "Secure Keyboard Entry" on, or a
        /// terminal password prompt, which look identical from outside. Deliver
        /// the text, but keep it out of history.
        case sensitive
        /// A password field. Deliver nothing, anywhere.
        case password
    }

    /// Classify the focused field. See `secureFieldVerdict(secureInput:…)`.
    func secureFieldVerdict() -> SecureFieldVerdict {
        let secureInput = isSecureInputActive
        let element = isTrusted ? focusedElement() : nil
        var subroleRef: CFTypeRef?
        if let element {
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        }
        let isSecureField = (subroleRef as? String) == (kAXSecureTextFieldSubrole as String)
        return Self.secureFieldVerdict(
            secureInput: secureInput,
            focusReadable: element != nil,
            focusedIsSecureField: isSecureField,
            ownerIsFrontmost: secureInput ? Self.secureInputOwnerIsFrontmost() : nil)
    }

    /// The decision itself, free of system calls so the self-test can cover it.
    ///
    /// The old rule was "secure input is on anywhere → password field", which
    /// threw away dictations into ordinary fields whenever an unrelated app held
    /// secure input. The focused field decides instead; secure input only counts
    /// when the app holding it is the one in front.
    ///
    /// - Parameter ownerIsFrontmost: nil when the holder can't be identified,
    ///   which is treated as "it might be" — the cautious reading.
    nonisolated static func secureFieldVerdict(
        secureInput: Bool, focusReadable: Bool,
        focusedIsSecureField: Bool, ownerIsFrontmost: Bool?
    ) -> SecureFieldVerdict {
        if focusedIsSecureField { return .password }
        guard secureInput else { return .normal }
        // Held by some other app: nothing to do with where the user is typing.
        guard ownerIsFrontmost ?? true else { return .normal }
        // The app in front holds it and won't say what has focus. Can't rule a
        // password field out, so don't risk it.
        guard focusReadable else { return .password }
        return .sensitive
    }

    /// Whether the process holding secure input belongs to the frontmost app.
    /// nil when the holder can't be identified.
    private static func secureInputOwnerIsFrontmost() -> Bool? {
        guard let owner = secureInputOwnerPID() else { return nil }
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        if owner == front.processIdentifier { return true }
        // A helper process inside the frontmost app's bundle counts as that app.
        if let frontPath = front.bundleURL?.standardizedFileURL.path,
           let ownerPath = NSRunningApplication(processIdentifier: owner)?
               .bundleURL?.standardizedFileURL.path,
           ownerPath == frontPath || ownerPath.hasPrefix(frontPath + "/") {
            return true
        }
        return false
    }

    /// The pid that switched secure input on, as the window server reports it.
    private static func secureInputOwnerPID() -> pid_t? {
        let key = "kCGSSessionSecureInputPID"
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let pid = session[key] as? NSNumber {
            return pid.int32Value
        }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        for user in users ?? [] {
            if let pid = user[key] as? NSNumber { return pid.int32Value }
        }
        return nil
    }

    /// `MURMUR_TEST_CAPTURE=1`: the verdict table, including the false positive
    /// that used to discard dictations (secure input held by a background app).
    nonisolated static func runSecureFieldSelfTest() -> Int {
        typealias V = SecureFieldVerdict
        let cases: [(name: String, secure: Bool, readable: Bool, field: Bool, front: Bool?, expect: V)] = [
            ("no secure input, normal field", false, true, false, nil, .normal),
            ("no secure input, nothing readable", false, false, false, nil, .normal),
            ("password field", true, true, true, true, .password),
            ("password field, secure input not reported", false, true, true, nil, .password),
            ("background app holds secure input, normal field", true, true, false, false, .normal),
            ("background app holds secure input, nothing readable", true, false, false, false, .normal),
            ("frontmost holds secure input, normal field (terminal)", true, true, false, true, .sensitive),
            ("frontmost holds secure input, nothing readable", true, false, false, true, .password),
            ("holder unknown, normal field", true, true, false, nil, .sensitive),
            ("holder unknown, nothing readable", true, false, false, nil, .password),
        ]
        var passed = 0
        for c in cases {
            let got = secureFieldVerdict(secureInput: c.secure, focusReadable: c.readable,
                                         focusedIsSecureField: c.field, ownerIsFrontmost: c.front)
            let ok = got == c.expect
            if ok { passed += 1 }
            print("[SecureField] \(ok ? "PASS" : "FAIL") \(c.name)  got=\(got) expect=\(c.expect)")
        }
        print("[SecureField] \(passed)/\(cases.count) passed")
        fflush(stdout)
        return cases.count - passed
    }

    init() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.appsAskedForAccessibility.remove(pid) }
        }
    }

    deinit {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
    }

    /// Shows the system Accessibility prompt if not yet trusted.
    @discardableResult
    func promptForTrust() -> Bool {
        // The constant's underlying value is "AXTrustedCheckOptionPrompt"; using
        // the literal sidesteps CFString/Unmanaged bridging differences.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether the currently focused element accepts typed text.
    func isEditableFieldFocused() -> Bool {
        guard isTrusted, let element = focusedElement() else { return false }

        // Settability, when the element answers the question at all. Many apps
        // don't implement it, so an unanswered query is treated as "maybe" and
        // the role decides — but a definite "no" is believed. Without this a
        // read-only text field (a disabled input, an API-key display) matched on
        // role alone, Cmd+V went nowhere, the notch said "Inserted", and the
        // restore timer then wiped the transcript off the clipboard too.
        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable)
        if settableStatus == .success, !settable.boolValue { return false }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, Self.editableRoles.contains(role) {
            return true
        }

        // Web text areas / contenteditable expose a settable value attribute even
        // when the role is generic.
        return settableStatus == .success && settable.boolValue
    }

    /// The element that will receive a paste right now, for callers that need to
    /// keep watching it afterwards.
    func focusedElementForEditing() -> AXUIElement? {
        guard isTrusted else { return nil }
        return focusedElement()
    }

    /// The focused element, asking the frontmost application directly when the
    /// system-wide query comes up empty.
    ///
    /// Electron apps — Claude, VS Code, Slack, Discord — ship with their
    /// accessibility tree switched off and expose nothing to the system-wide
    /// query, which returns `kAXErrorNoValue` (-25212). They build the tree only
    /// when an assistive app asks for it, by setting `AXManualAccessibility` on
    /// the application element. Until that happens Murmur can never confirm a
    /// text field is focused in those apps, so every dictation into them lands on
    /// the clipboard instead of in the field — the "it just says Copied" report.
    private func focusedElement() -> AXUIElement? {
        if let element = Self.copyFocusedElement(of: AXUIElementCreateSystemWide()) {
            return element
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        askForAccessibility(pid: pid)
        return Self.copyFocusedElement(of: AXUIElementCreateApplication(pid))
    }

    /// Ask the frontmost app to build its accessibility tree, before we need it.
    ///
    /// Asking is not instant — the app has to construct the tree — so doing it
    /// at delivery time is too late: the very first dictation into a given
    /// Electron app still found nothing and fell back to the clipboard, and only
    /// the next one landed. Called when recording starts instead, which buys the
    /// length of the dictation for the tree to come up.
    func primeFrontmostApp() {
        guard isTrusted, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        askForAccessibility(pid: pid)
    }

    private func askForAccessibility(pid: pid_t) {
        guard !appsAskedForAccessibility.contains(pid) else { return }
        appsAskedForAccessibility.insert(pid)
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), Self.manualAccessibility, kCFBooleanTrue)
    }

    /// Apps already asked to build their accessibility tree. Asking is cheap but
    /// not free (the app constructs the tree), so it's done once per process —
    /// and forgotten when that process dies. macOS reuses pids, so a set that
    /// only ever grew would eventually skip priming a NEW app that inherited a
    /// retired pid, silently reinstating the "Copied instead of pasted" bug for
    /// it until Murmur restarted.
    private var appsAskedForAccessibility: Set<pid_t> = []
    private var terminationObserver: NSObjectProtocol?
    private static let manualAccessibility = "AXManualAccessibility" as CFString

    private static func copyFocusedElement(of root: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &ref)
        guard status == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// What currently has focus, for diagnosing a clipboard fallback: which app
    /// is frontmost, the focused element's AX role, and whether its value is
    /// settable. Deliberately excludes the element's *value* — that is the user's
    /// text and must never reach a log.
    func focusDiagnostics() -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        guard isTrusted else { return "frontmost=\(frontmost) (not trusted — AX unreadable)" }

        guard let element = focusedElement() else {
            return "frontmost=\(frontmost) focused=none (app exposes no AX tree)"
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return "frontmost=\(frontmost) role=\(roleRef as? String ?? "?") subrole=\(subroleRef as? String ?? "-") valueSettable=\(settable.boolValue)"
    }

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]
}
