import SwiftUI

/// A consistent empty / zero-data state. Wraps the platform look but pins our
/// spacing and an optional call-to-action button, so every empty surface
/// (history, comparison, vocabulary) feels like the same app.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(Palette.accent.gradient)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(.mHeadline)
                    .foregroundStyle(Palette.textPrimary)
                Text(message)
                    .font(.mCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 320)
    }
}
