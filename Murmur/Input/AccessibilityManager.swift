import ApplicationServices
import AppKit
import Carbon.HIToolbox

/// Wraps the Accessibility (AX) APIs we need: permission state, detecting
/// whether the focused UI element accepts text, and the secure-input guard.
@MainActor
final class AccessibilityManager {
    /// Whether the app is trusted for Accessibility (required to read the
    /// focused element and to post synthetic key events).
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// True when a secure text field (e.g. a password field) is active. Synthetic
    /// paste is blocked in that state, so we fall back to clipboard-only.
    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

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

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, Self.editableRoles.contains(role) {
            return true
        }

        // Web text areas / contenteditable expose a settable value attribute even
        // when the role is generic.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
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
    /// not free (the app constructs the tree), so it's done once per process.
    private var appsAskedForAccessibility: Set<pid_t> = []
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
