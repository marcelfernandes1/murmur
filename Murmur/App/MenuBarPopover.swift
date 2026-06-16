import SwiftUI
import AppKit

/// The menu-bar dropdown, styled like macOS Control Center: a transparent window
/// with separate **floating glass modules** that blur the desktop behind them.
/// The accent appears only on the header glyph and the status dot — the glass and
/// layering carry the rest.
struct MenuBarPopover: View {
    let showHistory: () -> Void
    let showComparison: () -> Void
    let showSettings: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(DictationController.self) private var dictation
    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(spacing: Spacing.md) {
            header

            if !appState.accessibilityEnabled {
                NoticeRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: Palette.warning,
                    text: "Enable Accessibility to type into apps",
                    actionTitle: "Grant",
                    action: { dictation.enableAccessibility() }
                )
            }

            if let learned = appState.recentlyLearned {
                NoticeRow(
                    icon: "arrow.uturn.backward",
                    tint: prefs.accentTheme.adaptive,
                    text: "Learned “\(learned.corrected)”",
                    actionTitle: "Undo",
                    action: { dictation.undoLastLearned() }
                )
            }

            if !appState.lastTranscript.isEmpty {
                LastDictationCard(text: appState.lastTranscript)
            }

            quickActions

            footer
        }
        .padding(Spacing.lg)
        .frame(width: 300)
        .background(PopoverWindowConfigurator())
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(prefs.accentTheme.adaptive)
            VStack(alignment: .leading, spacing: 1) {
                Text("Murmur").font(.mHeadline)
                Text(appState.versionString)
                    .font(.mCaption2)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Spacing.sm)
            StatusBadge(kind: status.kind, label: status.label, animated: status.animated)
        }
    }

    // MARK: Quick actions (each its own floating glass bubble)

    private var quickActions: some View {
        HStack(spacing: Spacing.sm) {
            QuickTile(icon: "clock.arrow.circlepath", label: "History", action: showHistory)
            QuickTile(icon: "text.magnifyingglass", label: "Compare", action: showComparison)
            QuickTile(icon: "gearshape", label: "Settings", action: showSettings)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "command")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
            if !appState.shortcutHint.isEmpty {
                Text(appState.shortcutHint)
                    .font(.mCaption2)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.mCaption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(GhostButtonStyle())
            .keyboardShortcut("q")
        }
    }

    // MARK: Status mapping

    private var status: (kind: StatusKind, label: String, animated: Bool) {
        switch appState.status {
        case .error(let message):
            return (.error, "Error: \(message)".prefixForBadge, false)
        case .listening:
            return (.listening, "Listening", true)
        case .transcribing:
            return (.working, "Transcribing", true)
        case .idle:
            switch appState.modelPhase {
            case .preparing: return (.working, "Preparing", true)
            case .failed:    return (.error, "Model failed", false)
            case .idle, .ready: return (.success, "Ready", false)
            }
        }
    }
}

// MARK: - Pieces

/// A compact glass tile (icon chip over label), like a Control Center square.
private struct QuickTile: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Text(label)
                    .font(.mCaption2)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(hover ? Color.primary.opacity(0.08) : Color.clear,
                        in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.mQuick, value: hover)
        .accessibilityLabel(label)
    }
}

/// A background-less button that reveals a faint highlight only on hover / press —
/// so it reads as tappable without a resting fill, on the single glass panel.
private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Ghost(configuration: configuration)
    }

    private struct Ghost: View {
        let configuration: ButtonStyle.Configuration
        @State private var hover = false

        var body: some View {
            configuration.label
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(hover || configuration.isPressed ? Color.primary.opacity(0.10) : Color.clear,
                            in: .rect(cornerRadius: Radius.sm))
                .contentShape(.rect)
                .onHover { hover = $0 }
                .animation(.mQuick, value: hover)
        }
    }
}

/// An inline notice with a trailing glass action button (permission, undo).
private struct NoticeRow: View {
    let icon: String
    let tint: Color
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .imageScale(.medium)
            Text(text)
                .font(.mCaption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
            Spacer(minLength: Spacing.sm)
            Button(actionTitle, action: action)
                .buttonStyle(GhostButtonStyle())
        }
    }
}

/// The most recent transcript with a copy affordance.
private struct LastDictationCard: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("LAST DICTATION")
                    .font(.mCaption2)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.mCaption2)
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(GhostButtonStyle())
                .animation(.mQuick, value: copied)
            }
            Text(text)
                .font(.mCaption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: text) { copied = false }
    }
}

/// The menu-bar icon, reflecting dictation state.
struct MenuBarLabel: View {
    let appState: AppState

    var body: some View {
        Image(systemName: iconName)
            .accessibilityLabel("Murmur — \(iconName)")
    }

    private var iconName: String {
        switch appState.status {
        case .listening:    return "mic.fill"
        case .transcribing: return "ellipsis"
        case .error:        return "exclamationmark.triangle.fill"
        case .idle:         return "waveform"
        }
    }
}

/// Makes the hosting MenuBarExtra window transparent so the glass modules blur the
/// desktop directly — the Control Center effect — instead of sitting on an opaque
/// dark panel.
private struct PopoverWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

private extension String {
    /// Keep the status badge short — trim long error text.
    var prefixForBadge: String { count > 22 ? String(prefix(22)) + "…" : self }
}
