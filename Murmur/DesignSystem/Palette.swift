import SwiftUI

/// Murmur's color tokens. One source of truth for every surface.
///
/// Apple-native rule of thumb: prefer system-semantic colors (they adapt to
/// light/dark, increase-contrast, and vibrancy for free) and reserve the brand
/// hues for accent moments — the wordmark, the active waveform, primary actions.
enum Palette {

    // MARK: Brand

    /// The signature accent (matches the app icon's leading gradient stop).
    /// Defined in the asset catalog so it adapts in dark mode automatically.
    static let accent = Color.accentColor

    /// App-icon gradient stops, for hero moments (onboarding, wordmark, waveform).
    static let brandIndigo = Color(.sRGB, red: 0.361, green: 0.302, blue: 0.929, opacity: 1)
    static let brandViolet = Color(.sRGB, red: 0.640, green: 0.270, blue: 0.910, opacity: 1)

    /// The brand gradient, top-to-bottom like the icon.
    static let brandGradient = LinearGradient(
        colors: [brandIndigo, brandViolet],
        startPoint: .top, endPoint: .bottom)

    /// A subtler, wider brand sweep for large fills and glows.
    static let brandSheen = LinearGradient(
        colors: [brandIndigo.opacity(0.9), brandViolet.opacity(0.9)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Status (always paired with an icon — never color alone)

    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let info = Color.blue
    static let listening = accent

    // MARK: Text

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    /// For text laid over glass / dark notch backgrounds.
    static let textOnGlass = Color.white

    // MARK: Surfaces

    /// Solid reading surface (history rows, comparison bodies) — content layer.
    static let surface = Color(nsColor: .textBackgroundColor)
    /// Grouped window background.
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
    /// Hairline separators.
    static let separator = Color(nsColor: .separatorColor)
}
