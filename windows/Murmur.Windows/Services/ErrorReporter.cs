using System.Net.Http;

namespace Murmur.Windows.Services;

/// Ask-first error reporting. Problems are saved locally; nothing is sent until the
/// user agrees in the prompt. Declining deletes the saved reports.
internal static class ErrorReporter
{
    // Sentry project "murmur-windows". A DSN only allows sending reports; it is safe
    // to publish. Empty disables reporting entirely (no prompts, nothing saved).
    private const string Dsn = "";

    private static readonly SentryDsn? Target = SentryDsn.Parse(Dsn);
    private static readonly ErrorReportStore Store = new(Path.Combine(AppPaths.Root, "Reports"));
    private static readonly Lazy<ReportInfo> Info = new(() => ReportInfo.Current("murmur-windows"));
    private static bool prompting;

    public static bool Enabled => Target is not null;
    public static bool HasPending => Enabled && Store.Pending().Count > 0;
    /// Raised (on the recording thread) after a new problem is saved for review.
    public static event Action? Recorded;

    public static void Record(Exception error, bool handled, string mechanism)
    {
        CrashLog.Write(error);
        if (!Enabled) return;
        try
        {
            if (Store.Save(ErrorReport.CreateEvent(error, Info.Value, handled, mechanism, DateTimeOffset.Now))) Recorded?.Invoke();
        }
        catch (Exception inner) { CrashLog.Write(inner); }
    }

    /// Shows the send/don't-send prompt if any reports are waiting. UI thread only.
    public static async Task PromptAsync(bool afterCrash)
    {
        if (!HasPending || prompting) return;
        prompting = true;
        try
        {
            var title = afterCrash ? "Murmur closed unexpectedly" : "Murmur hit a problem";
            var answer = MessageBox.Show(
                $"{title}. Send an error report so it can be fixed?\n\n" +
                "The report includes technical error details, Murmur's version, and your Windows version. " +
                "It never includes your recordings, your words, or your name.",
                "Murmur", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.Yes);
            if (answer != MessageBoxResult.Yes) { Store.DiscardAll(); return; }
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            var failed = await Store.SendAllAsync(Target!, http, "murmur-windows/" + Info.Value.AppVersion, CancellationToken.None);
            if (failed > 0)
                MessageBox.Show("The report couldn't be sent right now. Murmur will ask again next time it starts.", "Murmur",
                    MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception e) { CrashLog.Write(e); }
        finally { prompting = false; }
    }
}
