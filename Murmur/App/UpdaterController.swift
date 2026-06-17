import Combine
import Sparkle

/// Owns Sparkle's updater for the lifetime of the app.
///
/// Murmur ships outside the Mac App Store (it's intentionally non-sandboxed —
/// see `Murmur.entitlements`), so Developer ID + notarization + Sparkle is the
/// update path. The standard controller reads `SUFeedURL` and `SUPublicEDKey`
/// from `Info.plist` and manages its own scheduled background checks; we just
/// expose a manual "Check for Updates…" action and whether it's currently
/// allowed (so the menu item can disable itself mid-check).
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    init() {
        // `startingUpdater: true` begins the scheduled-check timer immediately.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Trigger a user-initiated check; Sparkle drives the UI (progress, release
    /// notes, install + relaunch) from here.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
