import Foundation

/// What each release changed, in the user's language.
///
/// Kept as data rather than prose so the What's New window can show only the
/// versions someone actually skipped: updating from 0.4.9 straight to 0.5.3
/// should summarise everything in between, not just the newest entry.
enum ReleaseNotes {
    struct Highlight: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Release: Identifiable {
        /// Marketing version, e.g. "0.5.3".
        let version: String
        let headline: String
        let highlights: [Highlight]
        var id: String { version }
    }

    /// Newest first.
    static let all: [Release] = [
        Release(
            version: "0.5.3",
            headline: "Cloud transcription, and a lot fewer lost words",
            highlights: [
                Highlight(icon: "cloud.fill",
                          title: "OpenAI transcription",
                          detail: "Two new cloud models. One writes the words out as you speak."),
                Highlight(icon: "waveform.badge.exclamationmark",
                          title: "Long dictations keep their ending",
                          detail: "A take could stop mid-sentence and drop the rest. Fixed."),
                Highlight(icon: "text.badge.xmark",
                          title: "No more invented words",
                          detail: "Silence used to produce text anyway. Now it produces nothing."),
                Highlight(icon: "arrow.right.doc.on.clipboard",
                          title: "Pasting works in Claude, VS Code and Slack",
                          detail: "They hid their text fields from macOS. Murmur now asks."),
                Highlight(icon: "lock.shield",
                          title: "Safer at password prompts",
                          detail: "Nothing is left on your clipboard or saved to history."),
            ]
        ),
    ]

    /// Everything newer than `version`, newest first. An empty or unparseable
    /// `version` means a fresh install, which gets onboarding instead.
    static func releases(newerThan version: String?) -> [Release] {
        guard let version, !version.isEmpty else { return [] }
        return all.filter { compare($0.version, version) == .orderedDescending }
    }

    /// Numeric component comparison — "0.5.10" is newer than "0.5.9", which a
    /// plain string compare gets backwards.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The running app's marketing version.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
