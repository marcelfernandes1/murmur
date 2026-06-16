import SwiftUI

/// The content shown inside the dictation indicator, morphing between phases.
/// Colors adapt to the surface: **white** on the opaque black notch, **adaptive**
/// (primary / accent.adaptive) on the translucent floating glass pill — driven by
/// `model.isNotchScreen`, which mirrors the library's screen pick.
struct DictationNotchView: View {
    let model: NotchViewModel

    /// On the black notch everything is light regardless of system appearance; on
    /// the glass pill it follows the appearance so it stays legible on light/dark.
    private var onDark: Bool { model.isNotchScreen }
    private var mono: Color { onDark ? .white : .primary }
    private var accent: Color { onDark ? model.accent.onDark : model.accent.adaptive }

    var body: some View {
        HStack(spacing: Spacing.md) {
            content
        }
        .foregroundStyle(mono)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minWidth: 168)
        .animation(.mSmooth, value: phaseKey)
    }

    /// Identity that changes only when the *kind* of phase changes, so content
    /// swaps animate (a partial-text update within `.listening` does not).
    private var phaseKey: Int {
        switch model.phase {
        case .preparing:    return 0
        case .listening:    return 1
        case .transcribing: return 2
        case .done:         return 3
        case .learned:      return 4
        case .error:        return 5
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing(let message):
            PreparingRow(message: message, accent: accent, track: mono.opacity(0.15))
                .transition(.blurReplace)

        case .listening:
            ListeningRow(model: model, accent: accent)
                .transition(.blurReplace)

        case .transcribing:
            HStack(spacing: Spacing.sm) {
                BouncingDots(color: mono)
                Text("Transcribing…").font(.mCallout)
            }
            .transition(.blurReplace)

        case .done(let message):
            ConfirmRow(symbol: "checkmark.circle.fill", color: Palette.success, text: message)
                .transition(.blurReplace)

        case .learned(let term):
            ConfirmRow(symbol: "sparkles", color: accent, text: "Learned “\(term)”")
                .transition(.blurReplace)

        case .error(let message):
            ConfirmRow(symbol: "exclamationmark.triangle.fill",
                       color: Palette.warning,
                       text: message ?? "Something went wrong",
                       lineLimit: 2)
                .transition(.blurReplace)
        }
    }
}

// MARK: - Listening

/// The mic + live waveform, or the streaming partial transcript with a live dot.
private struct ListeningRow: View {
    let model: NotchViewModel
    let accent: Color

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if model.partialText.isEmpty {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                WaveformView(levels: model.levels, color: accent)
            } else {
                LiveDot()
                Text(model.partialText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .animation(.mQuick, value: model.partialText.isEmpty)
    }
}

/// A pulsing red dot — the universal "recording / live" signal.
private struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Palette.danger)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                       value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Preparing (honest, indeterminate)

/// Model loading. Core ML ANE specialization exposes no real progress, so instead
/// of a fake percentage bar we show an honest indeterminate sweep that simply
/// proves work is happening — it vanishes the instant the phase changes to ready.
private struct PreparingRow: View {
    let message: String
    var accent: Color = .white
    var track: Color = .white.opacity(0.15)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(message)
                .font(.mCallout)
                .lineLimit(2)
            IndeterminateBar(accent: accent, track: track)
        }
    }
}

private struct IndeterminateBar: View {
    var accent: Color = .white
    var track: Color = .white.opacity(0.15)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var width: CGFloat = 210
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let segW = geo.size.width * 0.4
            Capsule()
                .fill(track)
                .overlay(alignment: .leading) {
                    TimelineView(.animation(paused: reduceMotion)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let frac = (sin(t * 1.5) + 1) / 2 // smooth 0→1→0 sweep
                        Capsule()
                            .fill(accent)
                            .frame(width: segW)
                            .offset(x: CGFloat(frac) * max(0, geo.size.width - segW))
                    }
                }
                .clipShape(Capsule())
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Transcribing

private struct BouncingDots: View {
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = Double(i) * (2.0 * .pi / 3.0)
                    let y = reduceMotion ? 0 : -3.0 * sin(t * 3.0 + phase)
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .offset(y: CGFloat(y))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Terminal confirmations

/// A glyph that springs in next to a label — used for done / learned / error.
private struct ConfirmRow: View {
    let symbol: String
    let color: Color
    let text: String
    var lineLimit: Int = 1

    @State private var shown = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .scaleEffect(shown ? 1 : 0.4)
                .opacity(shown ? 1 : 0)
            Text(text)
                .font(.mCallout)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
        .onAppear { withAnimation(.mBounce) { shown = true } }
    }
}
