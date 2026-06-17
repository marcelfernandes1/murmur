import SwiftUI

/// Drives the notch content. Levels feed the live waveform; phase selects which
/// visual the notch shows.
@MainActor
@Observable
final class NotchViewModel {
    enum Phase {
        case preparing(String)
        case listening
        case transcribing
        case done(String)
        case learned(String)
        case error(String?)
    }

    static let barCount = 20
    private static let floor: CGFloat = 0.04

    // MARK: Waveform auto-gain
    //
    // Microphones differ wildly in absolute level: the built-in mic captures
    // speech ~17 dB quieter than AirPods over Bluetooth (HFP applies heavy
    // digital gain). A fixed multiplier makes one look dead and the other pin to
    // full. Instead we self-calibrate: track each mic's own noise floor and
    // speech peak, then map the live level between them so every mic fills the
    // waveform identically. This is display-only — the recorded/transcribed
    // audio is never touched.
    private static let attack: Float = 0.5       // how fast the peak rises to louder speech
    private static let release: Float = 0.04     // how slowly the peak falls after speech
    private static let floorFall: Float = 0.1    // how fast the noise floor follows dips
    private static let floorRise: Float = 0.01   // how slowly the noise floor creeps up
    private static let minSpan: Float = 0.006    // smallest peak-to-floor gap (guards silence)
    private static let gamma: CGFloat = 0.7      // perceptual curve (<1 lifts quiet speech)
    private static let liveliness: CGFloat = 1.4 // pushes normal speech toward a full, lively bar

    // Bar-height smoothing, applied once per fixed visual tick (see `pushLevel`).
    // Asymmetric so speech reads as responsive (fast attack) without jitter, and
    // settles gently (slower decay).
    private static let attackSmoothing: CGFloat = 0.6
    private static let decaySmoothing: CGFloat = 0.28

    private var peakEnv: Float = 0               // tracks recent speech peaks
    private var floorEnv: Float = 0              // tracks the ambient noise floor
    private var smoothedBar: CGFloat = floor     // last emitted bar height (for smoothing)

    var phase: Phase = .listening
    var levels: [CGFloat] = Array(repeating: floor, count: barCount)

    /// User-selected brand accent.
    var accent: AccentTheme = .blue

    /// Whether the indicator is showing in the opaque black notch (white content)
    /// vs the translucent floating glass pill (adaptive content). Set by
    /// `NotchController` before each show. Defaults true (safe for notched Macs).
    var isNotchScreen: Bool = true

    /// Live partial transcript shown during streaming.
    var partialText: String = ""

    /// Advance the rolling waveform by one bar from the interval RMS.
    ///
    /// Called once per fixed visual tick (~40 ms) by `NotchController`'s clock —
    /// NOT once per audio callback. That makes scroll speed and auto-gain
    /// reactivity independent of device callback cadence and buffer size, so a
    /// 48 kHz built-in mic, a 24 kHz AirPods mic, and any USB mic all scroll at
    /// the same rate.
    ///
    /// Normalizes the RMS against an adaptive noise floor and speech peak so the
    /// waveform looks the same whether the input is a quiet built-in mic or a loud
    /// Bluetooth headset, then lightly smooths the bar height. See the notes above.
    func pushLevel(_ rms: Float) {
        // Peak envelope: fast attack toward louder speech, slow release after.
        if rms > peakEnv {
            peakEnv += (rms - peakEnv) * Self.attack
        } else {
            peakEnv += (rms - peakEnv) * Self.release
        }
        // Noise-floor envelope: follows dips down, creeps up only slowly.
        if rms < floorEnv {
            floorEnv += (rms - floorEnv) * Self.floorFall
        } else {
            floorEnv += (rms - floorEnv) * Self.floorRise
        }

        // Map the live level into [0, 1] across this mic's own floor→peak span.
        // The minimum span keeps true silence (peak ≈ floor) pinned to the
        // baseline instead of amplifying ambient hiss to full scale.
        let span = max(peakEnv - floorEnv, Self.minSpan)
        let ratio = CGFloat(max(0, rms - floorEnv) / span)
        let shaped = pow(min(ratio, 1.0), Self.gamma) * Self.liveliness
        let target = min(1.0, max(Self.floor, shaped))

        // Light, asymmetric smoothing: rise quickly to new speech, fall gently.
        let coeff = target > smoothedBar ? Self.attackSmoothing : Self.decaySmoothing
        smoothedBar += (target - smoothedBar) * coeff

        var next = levels
        next.removeFirst()
        next.append(smoothedBar)
        levels = next
    }

    func reset() {
        levels = Array(repeating: Self.floor, count: Self.barCount)
        // Recalibrate from scratch so a mic switch between sessions adapts fresh.
        peakEnv = 0
        floorEnv = 0
        smoothedBar = Self.floor
    }
}
