import SwiftUI

/// Murmur's type scale. SF Pro throughout (Apple-native); the only flourish is a
/// rounded face reserved for the wordmark. Every size below supports Dynamic Type
/// because `.system(_:design:)` styles scale with the user's preferred size.
extension Font {

    /// Onboarding hero / wordmark. Rounded for a touch of warmth.
    static let mDisplay = Font.system(.largeTitle, design: .rounded).weight(.bold)

    /// Window / sheet titles.
    static let mTitle = Font.system(.title2).weight(.semibold)

    /// Section + card headers.
    static let mHeadline = Font.system(.headline)

    /// Default body copy.
    static let mBody = Font.system(.body)

    /// Emphasized body (button labels, active values).
    static let mCallout = Font.system(.callout).weight(.medium)

    /// Secondary / helper text.
    static let mCaption = Font.system(.caption)

    /// The smallest label (field captions, all-caps section eyebrows).
    static let mCaption2 = Font.system(.caption2)

    /// Transcripts and diffs — monospaced so edits line up.
    static let mMono = Font.system(.body, design: .monospaced)
}
