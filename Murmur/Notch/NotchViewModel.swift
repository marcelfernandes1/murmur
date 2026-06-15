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

    var phase: Phase = .listening
    var levels: [CGFloat] = Array(repeating: floor, count: barCount)

    /// Live partial transcript shown during streaming.
    var partialText: String = ""

    /// Append a new RMS level to the rolling waveform buffer.
    func pushLevel(_ rms: Float) {
        let normalized = min(1.0, max(Self.floor, CGFloat(rms) * 14.0))
        var next = levels
        next.removeFirst()
        next.append(normalized)
        levels = next
    }

    func reset() {
        levels = Array(repeating: Self.floor, count: Self.barCount)
    }
}
