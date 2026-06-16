import SwiftUI

/// First-run welcome flow: a five-step glass walkthrough that primes the two
/// permissions, picks a model, and ends with a **live practice field** so the
/// user sees a real dictation land before they finish.
struct OnboardingView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppState.self) private var appState
    @Environment(DictationController.self) private var dictation

    /// Called when the user finishes or skips to the end.
    var onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var practiceText = ""
    @FocusState private var practiceFocused: Bool

    enum Step: Int, CaseIterable { case welcome, microphone, accessibility, waveform, practice }

    private var accent: Color { prefs.accentTheme.adaptive }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            progressDots
            Spacer(minLength: 0)
            stepContent
            Spacer(minLength: 0)
            footer
        }
        .padding(Spacing.xxl)
        .frame(width: 560, height: 560)
        .background(accentGlow)
        .liquidGlassWindow()
        .onAppear { dictation.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dictation.refreshPermissions()
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            step(icon: "waveform", title: "Welcome to Murmur",
                 subtitle: "Hold a key, speak, and your words appear — transcribed privately, on-device. Nothing ever leaves your Mac.") {
                EmptyView()
            }

        case .microphone:
            step(icon: "mic.fill", title: "Microphone access",
                 subtitle: "Murmur records your voice locally to transcribe it. The audio is never uploaded.") {
                if appState.micEnabled {
                    StatusChip(kind: .success, label: "Microphone enabled")
                } else {
                    SecondaryButton(title: "Allow microphone", systemImage: "mic.fill") {
                        dictation.requestMicrophone()
                    }
                }
            }

        case .accessibility:
            step(icon: "keyboard", title: "Accessibility access",
                 subtitle: "Lets Murmur type transcriptions into whatever app you're using and use the Fn key as a trigger. Toggle Murmur on in System Settings, then come back.") {
                if appState.accessibilityEnabled {
                    StatusChip(kind: .success, label: "Accessibility enabled")
                } else {
                    SecondaryButton(title: "Open System Settings", systemImage: "arrow.up.forward.app") {
                        dictation.enableAccessibility()
                    }
                }
            }

        case .waveform:
            step(icon: "paintpalette.fill", title: "Pick your waveform color",
                 subtitle: "The color of the live waveform while you dictate. You can change it anytime in Settings.") {
                VStack(spacing: Spacing.lg) {
                    waveformPreview
                    accentSwatches
                    Text(prefs.accentTheme.displayName)
                        .font(.mCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

        case .practice:
            step(icon: "sparkles", title: "Try it now",
                 subtitle: "Hold \(triggerName) and say a sentence. Watch it land right here.") {
                VStack(spacing: Spacing.md) {
                    TextField("Your words will appear here…", text: $practiceText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.mBody)
                        .padding(Spacing.md)
                        .frame(maxWidth: 380, minHeight: 92, alignment: .topLeading)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: Radius.lg))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.lg)
                                .strokeBorder(practiceText.isEmpty ? Color.secondary.opacity(0.2) : accent.opacity(0.6),
                                              lineWidth: 1)
                        }
                        .focused($practiceFocused)

                    if !practiceText.isEmpty {
                        Label("That's it — you're dictating!", systemImage: "checkmark.circle.fill")
                            .font(.mCallout)
                            .foregroundStyle(Palette.success)
                            .transition(.opacity)
                    }
                }
                .animation(.mSnappy, value: practiceText.isEmpty)
                .onAppear { practiceFocused = true }
            }
        }
    }

    private func step<Controls: View>(icon: String, title: String, subtitle: String,
                                      @ViewBuilder controls: () -> Controls) -> some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: .circle)

            VStack(spacing: Spacing.sm) {
                Text(title).font(.mTitle)
                Text(subtitle)
                    .font(.mBody)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            controls()
                .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: 420)
    }

    // MARK: Chrome

    private var progressDots: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? accent : Color.secondary.opacity(0.3))
                    .frame(width: s == step ? 22 : 7, height: 7)
                    .animation(.mSnappy, value: step)
            }
        }
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                SecondaryButton(title: "Back") { back() }
            }
            Spacer()
            PrimaryButton(title: step == .practice ? "Finish" : "Continue",
                          systemImage: step == .practice ? "checkmark" : "arrow.right") {
                advance()
            }
        }
    }

    /// A soft accent glow layered over the glass window backdrop.
    private var accentGlow: some View {
        Circle()
            .fill(accent.opacity(0.18))
            .frame(width: 320, height: 320)
            .blur(radius: 90)
            .offset(y: -150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: Logic

    /// Live animated preview of the waveform in the chosen accent, on a dark
    /// notch-like backing so the color reads the way it will during dictation.
    private var waveformPreview: some View {
        AccentWaveformPreview(color: prefs.accentTheme.onDark)
            .padding(.vertical, Spacing.lg)
            .padding(.horizontal, Spacing.xl)
            .background(Color(red: 0.086, green: 0.086, blue: 0.090),
                        in: .rect(cornerRadius: Radius.xl))
    }

    private var accentSwatches: some View {
        HStack(spacing: Spacing.md) {
            ForEach(AccentTheme.allCases) { theme in
                Circle()
                    .fill(theme.swatch)
                    .frame(width: 26, height: 26)
                    .overlay { Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5) }
                    .overlay {
                        if prefs.accentTheme == theme {
                            Circle().strokeBorder(Color.primary, lineWidth: 2.5).padding(-4)
                        }
                    }
                    .contentShape(Circle())
                    .onTapGesture {
                        prefs.accentTheme = theme
                        dictation.applyAccent()
                    }
                    .help(theme.displayName)
                    .accessibilityLabel(theme.displayName)
                    .accessibilityAddTraits(prefs.accentTheme == theme ? [.isSelected] : [])
            }
        }
    }

    private var triggerName: String {
        let stripped = appState.shortcutHint.replacingOccurrences(of: "Trigger: ", with: "")
        return stripped.isEmpty ? "your hotkey" : stripped
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation(.mSmooth) { step = next }
        } else {
            onFinish()
        }
    }

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            withAnimation(.mSmooth) { step = prev }
        }
    }
}

/// A self-animating waveform used only to preview an accent color in onboarding.
private struct AccentWaveformPreview: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<22, id: \.self) { i in
                    let base = reduceMotion ? 0.5 : abs(sin(t * 3.0 + Double(i) * 0.55))
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 5 + 20 * base)
                }
            }
            .frame(height: 30)
            .shadow(color: color.opacity(0.4), radius: 3)
        }
        .accessibilityHidden(true)
    }
}
