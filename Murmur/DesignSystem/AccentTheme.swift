import SwiftUI
import AppKit

/// The user-selectable brand accent that drives the live waveform (and, over time,
/// the app's tint). Each theme carries a **bright** value for dark backgrounds and
/// a **deep** value for light ones, so legibility is designed in — not left to a
/// single hardcoded color washing out on the dark notch.
///
/// `adaptive` resolves bright-on-dark / deep-on-light automatically via an
/// `NSColor` dynamic provider — the standard Liquid Glass behavior, no per-surface
/// branching. The notch (always near-black) uses `onDark` directly.
enum AccentTheme: String, CaseIterable, Identifiable {
    case blue   // default
    case white
    case graphite
    case teal
    case coral
    case violet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue:     return "Vivid blue"
        case .white:    return "White"
        case .graphite: return "Graphite"
        case .teal:     return "Electric teal"
        case .coral:    return "Warm coral"
        case .violet:   return "Luminous violet"
        }
    }

    /// Bright variant — for dark backgrounds (the notch).
    var onDark: Color { Color(nsColor: darkNS) }

    /// Deep variant — for light backgrounds.
    var onLight: Color { Color(nsColor: lightNS) }

    /// Appearance-adaptive accent for surfaces that follow the system theme
    /// (menu bar, settings, onboarding).
    var adaptive: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNS : lightNS
        })
    }

    /// Representative swatch for pickers (the bright value reads well on both).
    var swatch: Color { onDark }

    private var darkNS: NSColor {
        switch self {
        case .blue:     return NSColor(srgbRed: 0.353, green: 0.690, blue: 1.000, alpha: 1) // #5AB0FF
        case .white:    return NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1) // #FFFFFF
        case .graphite: return NSColor(srgbRed: 0.682, green: 0.682, blue: 0.698, alpha: 1) // #AEAEB2
        case .teal:     return NSColor(srgbRed: 0.204, green: 0.882, blue: 0.831, alpha: 1) // #34E1D4
        case .coral:    return NSColor(srgbRed: 1.000, green: 0.541, blue: 0.357, alpha: 1) // #FF8A5B
        case .violet:   return NSColor(srgbRed: 0.706, green: 0.533, blue: 1.000, alpha: 1) // #B488FF
        }
    }

    private var lightNS: NSColor {
        switch self {
        case .blue:     return NSColor(srgbRed: 0.094, green: 0.373, blue: 0.647, alpha: 1) // #185FA5
        case .white:    return NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1) // #1C1C1E
        case .graphite: return NSColor(srgbRed: 0.388, green: 0.388, blue: 0.400, alpha: 1) // #636366
        case .teal:     return NSColor(srgbRed: 0.059, green: 0.431, blue: 0.337, alpha: 1) // #0F6E56
        case .coral:    return NSColor(srgbRed: 0.761, green: 0.255, blue: 0.047, alpha: 1) // #C2410C
        case .violet:   return NSColor(srgbRed: 0.420, green: 0.247, blue: 0.831, alpha: 1) // #6B3FD4
        }
    }
}
