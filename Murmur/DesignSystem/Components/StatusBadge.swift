import SwiftUI

/// A status is always an icon **and** a color (and usually a label) — never color
/// alone — so it reads for color-blind users and at a glance. This single type
/// replaces the ad-hoc green/orange `Text` scattered across the old views.
enum StatusKind: Equatable {
    case neutral
    case listening
    case working
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .neutral:   return Palette.textSecondary
        case .listening: return Palette.listening
        case .working:   return Palette.info
        case .success:   return Palette.success
        case .warning:   return Palette.warning
        case .error:     return Palette.danger
        }
    }

    var symbol: String {
        switch self {
        case .neutral:   return "circle.fill"
        case .listening: return "waveform"
        case .working:   return "ellipsis"
        case .success:   return "checkmark.circle.fill"
        case .warning:   return "exclamationmark.triangle.fill"
        case .error:     return "xmark.octagon.fill"
        }
    }
}

/// A small colored dot + label, e.g. the menu-bar header state row.
struct StatusBadge: View {
    var kind: StatusKind
    var label: String
    /// When true, the dot softly pulses (use for `.listening` / `.working`).
    var animated: Bool = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(kind.color)
                .frame(width: 8, height: 8)
                .scaleEffect(animated && pulse ? 1.35 : 1.0)
                .opacity(animated && pulse ? 0.55 : 1.0)
                .animation(animated ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil,
                           value: pulse)
            Text(label)
                .font(.mCallout)
                .foregroundStyle(Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) status")
        .onAppear { if animated { pulse = true } }
    }
}

/// An icon-led status chip for inline use (e.g. "Model ready" in Settings).
struct StatusChip: View {
    var kind: StatusKind
    var label: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: kind.symbol)
                .imageScale(.small)
            Text(label)
                .font(.mCaption)
        }
        .foregroundStyle(kind.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
