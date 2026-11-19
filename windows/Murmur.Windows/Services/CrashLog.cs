namespace Murmur.Windows.Services;

/// Error details for troubleshooting at %LOCALAPPDATA%\Murmur\murmur.log.
/// Records exception types and stack traces only, never dictated text.
internal static class CrashLog
{
    private static readonly object Sync = new();
    public static string PathName => Path.Combine(AppPaths.Root, "murmur.log");

    public static void Write(Exception? error)
    {
        if (error is null) return;
        try
        {
            lock (Sync)
            {
                Directory.CreateDirectory(AppPaths.Root);
                var file = new FileInfo(PathName);
                if (file.Exists && file.Length > 1_000_000) File.Move(PathName, PathName + ".old", overwrite: true);
                File.AppendAllText(PathName, $"{DateTimeOffset.Now:O} Murmur {typeof(CrashLog).Assembly.GetName().Version}{Environment.NewLine}{Describe(error)}{Environment.NewLine}");
            }
        }
        catch (Exception) { /* Logging must never take the app down. */ }
    }

    // Exception messages can echo input; keep the type, HRESULT, and stack only.
    private static string Describe(Exception error)
    {
        var text = $"{error.GetType().FullName} (0x{error.HResult:X8}){Environment.NewLine}{error.StackTrace}";
        return error.InnerException is null ? text : text + Environment.NewLine + "Caused by: " + Describe(error.InnerException);
    }
}
