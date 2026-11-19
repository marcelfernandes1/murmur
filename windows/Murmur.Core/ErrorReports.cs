using System.Diagnostics;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Murmur.Core;

/// Where error reports go: the envelope endpoint and public key from a Sentry DSN.
public sealed record SentryDsn(Uri EnvelopeUri, string PublicKey)
{
    public static SentryDsn? Parse(string? dsn)
    {
        if (string.IsNullOrWhiteSpace(dsn) || !Uri.TryCreate(dsn.Trim(), UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme != Uri.UriSchemeHttps || string.IsNullOrEmpty(uri.UserInfo)) return null;
        var projectId = uri.AbsolutePath.Trim('/');
        if (projectId.Length == 0 || !projectId.All(char.IsAsciiDigit)) return null;
        return new(new Uri($"https://{uri.Authority}/api/{projectId}/envelope/"), uri.UserInfo.Split(':')[0]);
    }
}

/// Builds a Sentry event from an exception. Reports carry exception types, stack
/// frames, and app/OS versions. They never carry recordings, transcripts, settings,
/// vocabulary, file contents, the user's name, or the machine name.
public static class ErrorReport
{
    // Only these types get their message included; their messages come from the
    // OS or runtime (missing DLLs, COM/Win32 codes, access paths), never from text
    // the user dictated. Other messages are dropped.
    private static readonly HashSet<string> SafeMessageTypes =
    [
        "System.DllNotFoundException", "System.BadImageFormatException", "System.EntryPointNotFoundException",
        "System.ComponentModel.Win32Exception", "System.Runtime.InteropServices.COMException",
        "System.Runtime.InteropServices.ExternalException", "System.IO.IOException", "System.IO.FileNotFoundException",
        "System.IO.DirectoryNotFoundException", "System.UnauthorizedAccessException", "System.OutOfMemoryException",
        "System.AccessViolationException", "System.TypeLoadException", "System.MissingMethodException",
        "System.NullReferenceException", "System.IndexOutOfRangeException", "System.ArgumentOutOfRangeException",
        "System.ObjectDisposedException", "System.InvalidCastException", "System.NotSupportedException",
        "System.PlatformNotSupportedException", "System.TimeoutException", "System.Net.Http.HttpRequestException"
    ];

    public static JsonObject CreateEvent(Exception error, ReportInfo info, bool handled, string mechanism, DateTimeOffset now)
    {
        var chain = new List<Exception>();
        for (var current = error; current is not null && chain.Count < 8; current = current.InnerException) chain.Add(current);
        chain.Reverse(); // Sentry lists the root cause first and the outermost exception last.
        var values = new JsonArray();
        foreach (var exception in chain)
        {
            var type = exception.GetType().FullName ?? exception.GetType().Name;
            var value = SafeMessageTypes.Contains(type) ? Scrub(exception.Message, info) : $"HRESULT 0x{exception.HResult:X8}";
            values.Add(new JsonObject
            {
                ["type"] = type,
                ["value"] = value.Length > 400 ? value[..400] : value,
                ["module"] = exception.GetType().Assembly.GetName().Name,
                ["stacktrace"] = new JsonObject { ["frames"] = Frames(exception) },
                ["mechanism"] = new JsonObject { ["type"] = mechanism, ["handled"] = handled }
            });
        }
        return new JsonObject
        {
            ["event_id"] = Guid.NewGuid().ToString("N"),
            ["timestamp"] = now.ToUniversalTime().ToString("O"),
            ["platform"] = "csharp",
            ["level"] = handled ? "error" : "fatal",
            ["release"] = info.Release,
            ["environment"] = "production",
            ["tags"] = new JsonObject { ["handled"] = handled ? "yes" : "no", ["mechanism"] = mechanism },
            ["contexts"] = new JsonObject
            {
                ["os"] = new JsonObject { ["name"] = info.OsName, ["version"] = info.OsVersion },
                ["runtime"] = new JsonObject { ["name"] = ".NET", ["version"] = info.RuntimeVersion },
                ["device"] = new JsonObject { ["arch"] = info.Architecture, ["processor_count"] = info.ProcessorCount }
            },
            ["exception"] = new JsonObject { ["values"] = values },
            // Ask Sentry not to record the sender's IP address.
            ["sdk"] = new JsonObject
            {
                ["name"] = "murmur.windows", ["version"] = info.AppVersion,
                ["settings"] = new JsonObject { ["infer_ip"] = "never" }
            }
        };
    }

    /// The same failure from the same place produces the same signature, so one bug
    /// queues one report instead of one per occurrence.
    public static string Signature(JsonObject report)
    {
        var builder = new StringBuilder();
        foreach (var value in report["exception"]?["values"]?.AsArray() ?? [])
        {
            builder.Append(value?["type"]).Append('|');
            var frames = value?["stacktrace"]?["frames"]?.AsArray();
            var top = frames?.LastOrDefault(f => f?["in_app"]?.GetValue<bool>() == true) ?? frames?.LastOrDefault();
            builder.Append(top?["function"]).Append(';');
        }
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())))[..16].ToLowerInvariant();
    }

    private static JsonArray Frames(Exception exception)
    {
        var frames = new JsonArray();
        var trace = new StackTrace(exception, fNeedFileInfo: true).GetFrames();
        // Sentry expects the oldest call first.
        for (var i = trace.Length - 1; i >= 0; i--)
        {
            var frame = trace[i];
            var method = frame.GetMethod();
            if (method is null) continue;
            var type = method.DeclaringType;
            var name = method.Name;
            // Async and lambda bodies compile to "<Method>d__12.MoveNext"; show "Method".
            if (type is not null && type.Name.StartsWith('<') && type.DeclaringType is not null)
            {
                var end = type.Name.IndexOf('>');
                if (end > 1) name = type.Name[1..end];
                type = type.DeclaringType;
            }
            var json = new JsonObject
            {
                ["function"] = (type?.FullName ?? "") + "." + name,
                ["module"] = method.Module.Assembly.GetName().Name,
                ["in_app"] = type?.Namespace?.StartsWith("Murmur", StringComparison.Ordinal) == true
            };
            var file = frame.GetFileName();
            if (file is not null)
            {
                // Build paths are CI paths; keep them relative to the repository.
                var index = file.Replace('\\', '/').IndexOf("/windows/", StringComparison.Ordinal);
                json["filename"] = index >= 0 ? file[(index + 1)..].Replace('\\', '/') : Path.GetFileName(file);
                if (frame.GetFileLineNumber() > 0) json["lineno"] = frame.GetFileLineNumber();
            }
            frames.Add(json);
        }
        return frames;
    }

    /// Removes the user's account name and profile path from OS-provided messages.
    public static string Scrub(string text, ReportInfo info)
    {
        if (!string.IsNullOrEmpty(info.UserProfile)) text = text.Replace(info.UserProfile, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        if (info.UserName.Length >= 2) text = text.Replace(info.UserName, "<user>", StringComparison.OrdinalIgnoreCase);
        if (info.MachineName.Length >= 2) text = text.Replace(info.MachineName, "<computer>", StringComparison.OrdinalIgnoreCase);
        return text;
    }

    /// The envelope body Sentry's ingest endpoint accepts.
    public static byte[] Envelope(JsonObject report, DateTimeOffset now)
    {
        var payload = Encoding.UTF8.GetBytes(report.ToJsonString());
        var header = new JsonObject { ["event_id"] = report["event_id"]?.GetValue<string>(), ["sent_at"] = now.ToUniversalTime().ToString("O") };
        var item = new JsonObject { ["type"] = "event", ["length"] = payload.Length, ["content_type"] = "application/json" };
        using var stream = new MemoryStream();
        stream.Write(Encoding.UTF8.GetBytes(header.ToJsonString() + "\n" + item.ToJsonString() + "\n"));
        stream.Write(payload);
        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }
}

public sealed record ReportInfo(string Release, string AppVersion, string OsName, string OsVersion, string RuntimeVersion,
    string Architecture, int ProcessorCount, string UserName, string UserProfile, string MachineName)
{
    public static ReportInfo Current(string product)
    {
        var version = Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "0.0.0";
        return new($"{product}@{version}", version,
            OperatingSystem.IsWindows() ? "Windows" : RuntimeInformation.OSDescription, Environment.OSVersion.Version.ToString(),
            Environment.Version.ToString(), RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
            Environment.ProcessorCount, Environment.UserName, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.MachineName);
    }
}

/// Reports wait on disk until the user agrees to send them. Declining deletes them.
public sealed class ErrorReportStore(string directory, int limit = 10)
{
    public string Directory => directory;

    public bool Save(JsonObject report)
    {
        System.IO.Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, ErrorReport.Signature(report) + ".json");
        if (File.Exists(path)) return false; // The same problem is already waiting.
        var existing = Pending();
        foreach (var old in existing.Take(Math.Max(0, existing.Count - limit + 1))) TryDelete(old);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, report.ToJsonString());
        File.Move(temporary, path, overwrite: true);
        return true;
    }

    /// Pending reports, oldest first.
    public List<string> Pending() => System.IO.Directory.Exists(directory)
        ? new DirectoryInfo(directory).GetFiles("*.json").OrderBy(f => f.LastWriteTimeUtc).Select(f => f.FullName).ToList()
        : [];

    public void DiscardAll() { foreach (var path in Pending()) TryDelete(path); }

    /// Sends every pending report. Returns how many could not be sent; those stay queued.
    public async Task<int> SendAllAsync(SentryDsn dsn, HttpClient http, string client, CancellationToken token)
    {
        var failed = 0;
        foreach (var path in Pending())
        {
            JsonObject? report;
            try { report = JsonNode.Parse(await File.ReadAllTextAsync(path, token)) as JsonObject; }
            catch (Exception e) when (e is JsonException or IOException) { TryDelete(path); continue; }
            if (report is null) { TryDelete(path); continue; }
            using var request = new HttpRequestMessage(HttpMethod.Post, dsn.EnvelopeUri)
            {
                Content = new ByteArrayContent(ErrorReport.Envelope(report, DateTimeOffset.Now))
            };
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/x-sentry-envelope");
            request.Headers.TryAddWithoutValidation("X-Sentry-Auth", $"Sentry sentry_version=7, sentry_key={dsn.PublicKey}, sentry_client={client}");
            try
            {
                using var response = await http.SendAsync(request, token);
                var status = (int)response.StatusCode;
                // 2xx: delivered. 4xx (except rate limits): Sentry will never accept it; drop it.
                if (response.IsSuccessStatusCode || status is >= 400 and < 500 and not 429) TryDelete(path);
                if (!response.IsSuccessStatusCode) failed++;
            }
            catch (HttpRequestException) { failed++; }
        }
        return failed;
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
