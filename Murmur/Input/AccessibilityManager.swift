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
        guard isTrusted else { return false }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard status == .success,
              let ref = focusedRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        let element = ref as! AXUIElement

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

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]
}
