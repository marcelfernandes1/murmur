import SwiftUI

/// A live catalog of every design-system token and component. Open the canvas on
/// this file to review the whole visual language at once. Not shipped in any
/// window — it exists purely as a `#Preview` and a compile-time consumer that
/// proves the kit renders.
private struct DesignSystemGallery: View {
    @Namespace private var glassNS

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {

                group("Brand") {
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .fill(Palette.brandGradient)
                        .frame(height: 64)
                        .overlay(
                            Text("Murmur")
                                .font(.mDisplay)
                                .foregroundStyle(.white))
                }

                group("Type scale") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Display").font(.mDisplay)
                        Text("Title").font(.mTitle)
                        Text("Headline").font(.mHeadline)
                        Text("Body — the quick brown fox").font(.mBody)
                        Text("Callout / button label").font(.mCallout)
                        Text("Caption helper text").font(.mCaption)
                            .foregroundStyle(Palette.textSecondary)
                        Text("monospaced transcript 12:34").font(.mMono)
                    }
                }

                group("Status") {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        StatusBadge(kind: .listening, label: "Listening", animated: true)
                        StatusBadge(kind: .working, label: "Transcribing", animated: true)
                        StatusBadge(kind: .success, label: "Ready")
                        HStack(spacing: Spacing.md) {
                            StatusChip(kind: .success, label: "Model ready")
                            StatusChip(kind: .warning, label: "Not granted")
                            StatusChip(kind: .error, label: "Failed")
                        }
                    }
                }

                group("Buttons") {
                    HStack(spacing: Spacing.md) {
                        PrimaryButton(title: "Continue", systemImage: "arrow.right") {}
                        SecondaryButton(title: "Skip") {}
                    }
                }

                group("Glass surfaces") {
                    GlassEffectContainer(spacing: Spacing.md) {
                        HStack(spacing: Spacing.md) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text("Glass card").font(.mHeadline)
                                    Text("Control / nav layer only")
                                        .font(.mCaption)
                                        .foregroundStyle(Palette.textSecondary)
                                }
                            }
                            GlassPill(tint: Palette.accent) {
                                Label("Pill", systemImage: "waveform")
                                    .font(.mCallout)
                            }
                        }
                    }
                }

                group("Empty state") {
                    EmptyStateView(
                        symbol: "waveform",
                        title: "No transcripts yet",
                        message: "Hold your hotkey and speak — your dictations will appear here.",
                        actionTitle: "Open Settings") {}
                }
            }
            .padding(Spacing.xl)
        }
        .frame(width: 520)
        .background(Palette.brandSheen.opacity(0.12))
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(.mCaption2)
                .foregroundStyle(Palette.textSecondary)
            content()
        }
    }
}

#Preview("Design System") {
    DesignSystemGallery()
}
