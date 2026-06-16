import SwiftUI

/// Primary action — the accent-tinted, prominent Liquid Glass button. One per
/// view, reserved for the main thing the user should do (Continue, Grant, Save).
struct PrimaryButton: View {
    var title: String
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.mCallout)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.accent)
    }
}

/// Secondary action — plain Liquid Glass, no tint. Cancel, Skip, tertiary nav.
struct SecondaryButton: View {
    var title: String
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.mCallout)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
        }
        .buttonStyle(.glass)
    }
}
