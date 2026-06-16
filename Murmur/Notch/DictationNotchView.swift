import SwiftUI

/// The content shown inside the expanded notch, switching by phase.
struct DictationNotchView: View {
    let model: NotchViewModel

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minWidth: 160)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing(let message):
            PreparingView(message: message)

        case .listening:
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
            if model.partialText.isEmpty {
                WaveformView(levels: model.levels)
            } else {
                Text(model.partialText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 260, alignment: .leading)
            }

        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Transcribing…")
                .font(.system(size: 13, weight: .medium))

        case .done(let message):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))

        case .learned(let term):
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("Learned “\(term)”")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message ?? "Something went wrong")
                .font(.system(size: 13))
                .lineLimit(1)
        }
    }
}

/// Model-loading view with a continuously-advancing bar. Core ML's Neural Engine
/// "specialization" (the one-time, multi-minute compile on first load / after an
/// OS update) exposes no real progress signal, so the bar is driven by elapsed
/// time on an ease-out curve that always creeps forward but never reaches 100%.
/// The point is to prove the app is working, not to time it precisely — the bar
/// vanishes the moment the model goes `.ready` and the phase changes.
private struct PreparingView: View {
    let message: String

    /// Rough wall-clock of a cold large-turbo ANE compile on Apple Silicon.
    private let expected: TimeInterval = 150
    @State private var start = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            TimelineView(.periodic(from: start, by: 0.1)) { ctx in
                let elapsed = max(0, ctx.date.timeIntervalSince(start))
                // Ease-out asymptote toward ~0.95: fast at first, never "stuck".
                let fraction = min(0.95, 1 - exp(-elapsed / (expected * 0.4)))
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 210)
            }
        }
    }
}
