import AppKit
import Foundation
import Sentry

/// Ask-first crash reporting. Sentry's crash handler records a crash to disk; on
/// the next launch, before anything is sent, `beforeSend` moves the report into
/// our own pending folder and returns nil. The user then chooses Send or Don't
/// Send. Declining deletes the report. Nothing is uploaded without a yes.
///
/// Reports carry the crash stack, app version, and Mac model/macOS version. They
/// never carry recordings, transcripts, vocabulary, history, or breadcrumbs.
enum CrashReporter {
    /// Sentry project "murmur-mac". A DSN only allows sending reports; it is safe
    /// to publish. Empty disables crash reporting entirely.
    static let dsn = ""

    private static let pendingDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/CrashReports", isDirectory: true)
    }()
    @MainActor private static var prompting = false

    static func start() {
        guard !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableUncaughtNSExceptionReporting = true
            // Crashes only: no sessions, tracing, hangs, network capture, or breadcrumbs.
            options.enableAutoSessionTracking = false
            options.enableAutoPerformanceTracing = false
            options.enableAppHangTracking = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableAutoBreadcrumbTracking = false
            options.enableCaptureFailedRequests = false
            options.enableSwizzling = false
            options.maxBreadcrumbs = 0
            options.beforeSend = { event in
                save(event)
                DispatchQueue.main.async { Task { await promptIfNeeded() } }
                return nil // Held for the user's answer; never sent automatically.
            }
        }
        // Reports from a launch where the user quit before answering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Task { await promptIfNeeded() } }
    }

    private static func save(_ event: Event) {
        var payload = event.serialize()
        payload["user"] = nil
        payload["breadcrumbs"] = nil
        payload["server_name"] = nil
        var sdk = payload["sdk"] as? [String: Any] ?? [:]
        sdk["settings"] = ["infer_ip": "never"] // Ask Sentry not to record the sender's IP.
        payload["sdk"] = sdk
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        let id = (payload["event_id"] as? String) ?? UUID().uuidString
        try? data.write(to: pendingDirectory.appendingPathComponent("\(id).json"), options: .atomic)
    }

    private static func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    @MainActor
    static func promptIfNeeded() async {
        let reports = pending()
        guard !reports.isEmpty, !prompting else { return }
        prompting = true
        defer { prompting = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Murmur quit unexpectedly"
        alert.informativeText = "Send a crash report so it can be fixed? The report includes technical crash details, Murmur's version, and your Mac model and macOS version. It never includes your recordings, your words, or your name."
        alert.addButton(withTitle: "Send Report")
        alert.addButton(withTitle: "Don't Send")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            reports.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        for url in reports where await send(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Posts one saved report as a Sentry envelope. True when Sentry accepted it,
    /// or rejected it for good (so it isn't retried forever).
    private static func send(_ url: URL) async -> Bool {
        guard let dsnURL = URL(string: dsn), let host = dsnURL.host, let key = dsnURL.user,
              let projectId = dsnURL.pathComponents.last,
              let endpoint = URL(string: "https://\(host)/api/\(projectId)/envelope/") else { return true }
        guard let payload = try? Data(contentsOf: url),
              let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let eventId = event["event_id"] as? String else { return true }
        let header: [String: Any] = ["event_id": eventId, "sent_at": ISO8601DateFormatter().string(from: Date())]
        let item: [String: Any] = ["type": "event", "length": payload.count, "content_type": "application/json"]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let itemData = try? JSONSerialization.data(withJSONObject: item) else { return true }
        var body = headerData; body.append(0x0A); body.append(itemData); body.append(0x0A); body.append(payload); body.append(0x0A)

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        request.setValue("Sentry sentry_version=7, sentry_key=\(key), sentry_client=murmur-mac/\(version)", forHTTPHeaderField: "X-Sentry-Auth")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status) || (400..<500).contains(status) && status != 429
    }
}
