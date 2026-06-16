import SwiftUI

/// A consistent section header for the redesigned Settings / windows: an optional
/// SF Symbol, a title, and an optional inline info affordance that demotes the
/// old always-visible gray help paragraphs into a tappable popover.
struct SectionHeader: View {
    var title: String
    var systemImage: String? = nil
    var help: String? = nil

    @State private var showHelp = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Palette.accent)
                    .imageScale(.medium)
            }
            Text(title)
                .font(.mHeadline)
                .foregroundStyle(Palette.textPrimary)

            if let help {
                Button { showHelp.toggle() } label: {
                    Image(systemName: "info.circle")
                        .imageScale(.small)
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help(help)
                .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                    Text(help)
                        .font(.mCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(Spacing.md)
                        .frame(maxWidth: 260)
                }
                .accessibilityLabel("More info: \(title)")
            }
            Spacer(minLength: 0)
        }
    }
}
