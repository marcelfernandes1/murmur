import SwiftUI

/// Shown once after an update: what changed, then an optional setup step for
/// the OpenAI key.
///
/// Deliberately two screens, not one. A changelog and a credential form are
/// different jobs — stacking them makes the update feel like a chore and buries
/// the setup at the bottom of a scroll. The key step can be skipped, and is
/// skipped entirely for anyone who already has a key saved.
struct WhatsNewView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(DictationController.self) private var dictation

    let releases: [ReleaseNotes.Release]
    var onFinish: () -> Void

    /// `MURMUR_PREVIEW_WHATSNEW=openai` opens straight on the setup page.
    @State private var page: Page =
        ProcessInfo.processInfo.environment["MURMUR_PREVIEW_WHATSNEW"] == "openai" ? .openAI : .highlights
    @State private var apiKey = ""
    /// `MURMUR_PREVIEW_WHATSNEW=1` forces the setup step to render as if no key
    /// were saved, so the flow can be reviewed without deleting a real one.
    @State private var savedKey = APIKeyStore.hasKey
        && ProcessInfo.processInfo.environment["MURMUR_PREVIEW_WHATSNEW"] == nil
    @FocusState private var keyFocused: Bool

    private enum Page { case highlights, openAI }

    private var accent: Color { prefs.accentTheme.adaptive }
    /// Skip the setup page for anyone already set up.
    private var showsOpenAIStep: Bool { !savedKey }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(Spacing.xxl)
        .frame(width: 560, height: 640)
        .background(accentGlow)
        .liquidGlassWindow()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(page == .highlights ? "What's new" : "OpenAI transcription")
                .font(.mDisplay)
            Text(page == .highlights ? subtitle : "Optional — Murmur works fully offline without this.")
                .font(.mBody)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        guard let newest = releases.first else { return "Murmur has been updated." }
        return releases.count == 1
            ? newest.headline
            : "\(newest.headline) — plus everything from \(releases.count - 1) earlier update\(releases.count == 2 ? "" : "s")."
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch page {
        case .highlights:
            // Fills the window; the list is the page.
            highlights
        case .openAI:
            // Three short steps and a field do not fill a window the height of a
            // changelog, and pinning them to the top left a dead slab above the
            // buttons. Centre them instead of resizing the window mid-flow,
            // which would be jarring.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                openAISetup
                Spacer(minLength: 0)
            }
        }
    }

    private var highlights: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(releases) { release in
                    if releases.count > 1 {
                        Text(release.version)
                            .font(.mCaption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, Spacing.sm)
                    }
                    ForEach(release.highlights) { highlight in
                        highlightRow(highlight)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func highlightRow(_ highlight: ReleaseNotes.Highlight) -> some View {
        GlassCard(cornerRadius: Radius.lg, padding: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: highlight.icon)
                    .font(.system(.title3))
                    .foregroundStyle(accent)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(highlight.title).font(.mHeadline)
                    Text(highlight.detail)
                        .font(.mCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: OpenAI setup

    private var openAISetup: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            GlassCard(cornerRadius: Radius.lg, padding: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(Array(setupSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                            Text("\(index + 1)")
                                .font(.mCaption)
                                .foregroundStyle(accent)
                                .frame(width: 16, alignment: .center)
                            Text(step)
                                .font(.mBody)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                        Label("Open platform.openai.com/api-keys", systemImage: "arrow.up.forward.square")
                            .font(.mCallout)
                    }
                    .padding(.top, Spacing.xs)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.mMono)
                    .focused($keyFocused)
                    .onSubmit(saveKey)
                if savedKey {
                    StatusChip(kind: .success, label: "Key saved to your Keychain")
                } else {
                    Text("Stored in the macOS Keychain — never in Murmur's settings file, and never sent anywhere but OpenAI.")
                        .font(.mCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var setupSteps: [String] {
        [
            "Sign in to OpenAI and open the API keys page.",
            "Create a new secret key and copy it.",
            "Paste it below — then pick an OpenAI model in Settings ▸ Advanced.",
        ]
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            if page == .openAI {
                SecondaryButton(title: "Back") { withAnimation(.mQuick) { page = .highlights } }
            }
            Spacer()
            if page == .highlights, showsOpenAIStep {
                SecondaryButton(title: "Not now") { onFinish() }
                PrimaryButton(title: "Set up OpenAI", systemImage: "arrow.right") {
                    withAnimation(.mQuick) { page = .openAI }
                    keyFocused = true
                }
            } else if page == .openAI {
                PrimaryButton(title: savedKey ? "Done" : "Save key",
                              systemImage: savedKey ? "checkmark" : "key.fill") {
                    if savedKey { onFinish() } else { saveKey() }
                }
            } else {
                PrimaryButton(title: "Done", systemImage: "checkmark") { onFinish() }
            }
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { keyFocused = true; return }
        guard APIKeyStore.save(trimmed) else { return }
        // Never keep the key in view state.
        apiKey = ""
        savedKey = true
        dictation.applyModel()
    }

    /// A soft wash of the user's accent behind the glass, matching onboarding.
    private var accentGlow: some View {
        RadialGradient(colors: [accent.opacity(0.28), .clear],
                       center: .topLeading, startRadius: 0, endRadius: 620)
            .ignoresSafeArea()
    }
}
