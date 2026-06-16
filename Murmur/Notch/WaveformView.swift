import SwiftUI

/// The live dictation waveform — a row of capsule bars whose heights track recent
/// audio levels, filled with the user's adaptive accent and a faint matching glow.
/// During silence the bars settle to a gently *breathing* baseline instead of a
/// dead-flat line, so the notch always reads as "alive and listening."
struct WaveformView: View {
    let levels: [CGFloat]
    /// Bar fill — pass the accent's bright (`onDark`) variant for the notch.
    var color: Color = .white
    var maxHeight: CGFloat = 24
    var glow: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: barHeight(at: i, time: t))
                }
            }
            .frame(height: maxHeight, alignment: .center)
            .shadow(color: glow ? color.opacity(0.45) : .clear,
                    radius: glow ? 3 : 0)
            .animation(.mWaveform, value: levels)
        }
        .accessibilityHidden(true)
    }

    /// Combine the real audio level with a subtle per-bar sine "breath" so silence
    /// looks like quiet attention rather than a flat dead signal.
    private func barHeight(at i: Int, time t: TimeInterval) -> CGFloat {
        let level = levels[i]
        let breatheBase: Double = 0.06
        let breathe: Double
        if reduceMotion {
            breathe = breatheBase
        } else {
            let phase = Double(i) * 0.5
            breathe = breatheBase + 0.03 * (sin(t * 2.2 + phase) + 1) / 2
        }
        return max(3, CGFloat(breathe) * maxHeight, level * maxHeight)
    }
}
