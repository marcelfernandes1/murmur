import SwiftUI

/// One shared motion vocabulary so every transition in the app feels related.
/// Liquid Glass morphs (`glassEffectID`) look best on springs, not linear curves.
extension Animation {

    /// Default for state changes, taps, value updates. Crisp, minimal overshoot.
    static let mSnappy = Animation.spring(response: 0.30, dampingFraction: 0.80)

    /// Larger layout / glass-morph transitions. Smoother settle.
    static let mSmooth = Animation.spring(response: 0.45, dampingFraction: 0.85)

    /// Playful confirmations (done checkmark, "learned" sparkle). Light bounce.
    static let mBounce = Animation.spring(response: 0.40, dampingFraction: 0.62)

    /// Fast fades / hovers where a spring would feel heavy.
    static let mQuick = Animation.easeOut(duration: 0.16)

    /// The live waveform level updates — short so bars stay responsive.
    static let mWaveform = Animation.easeOut(duration: 0.12)
}
