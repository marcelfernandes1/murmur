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
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

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
