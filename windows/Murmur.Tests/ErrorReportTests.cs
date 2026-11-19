using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Murmur.Core;
using Xunit;

namespace Murmur.Tests;

public sealed class ErrorReportTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "murmur-reports-" + Guid.NewGuid());
    private static readonly ReportInfo Info = new("murmur-windows@0.1.3", "0.1.3", "Windows", "10.0.26100", "10.0.0",
        "x64", 8, "Jesse", @"C:\Users\Jesse", "JESSE-LAPTOP");

    private static Exception Thrown(Func<Exception> make)
    {
        try { throw make(); } catch (Exception e) { return e; }
    }

    [Fact] public void DsnParsesToEnvelopeEndpoint()
    {
        var dsn = SentryDsn.Parse("https://abc123@o42.ingest.us.sentry.io/4507");
        Assert.NotNull(dsn);
        Assert.Equal("https://o42.ingest.us.sentry.io/api/4507/envelope/", dsn.EnvelopeUri.ToString());
        Assert.Equal("abc123", dsn.PublicKey);
        Assert.Null(SentryDsn.Parse(""));
        Assert.Null(SentryDsn.Parse("http://abc@o42.ingest.sentry.io/1"));
        Assert.Null(SentryDsn.Parse("https://o42.ingest.sentry.io/1"));
    }

    [Fact] public void UserTextNeverEntersReports()
    {
        const string spoken = "my secret dictation about the Henderson deal";
        var error = Thrown(() => new InvalidOperationException("Failed on: " + spoken, new FormatException(spoken)));
        var json = ErrorReport.CreateEvent(error, Info, handled: true, "test", DateTimeOffset.Now).ToJsonString();
        Assert.DoesNotContain("Henderson", json);
        Assert.Contains("System.InvalidOperationException", json);
        Assert.Contains("System.FormatException", json);
        Assert.Contains("\"infer_ip\":\"never\"", json);
    }

    [Fact] public void OsMessagesKeepDetailButLoseTheUsersName()
    {
        var error = Thrown(() => new DllNotFoundException(@"Unable to load C:\Users\Jesse\AppData\Local\Programs\Murmur\whisper.dll on JESSE-LAPTOP"));
        var report = ErrorReport.CreateEvent(error, Info, handled: false, "test", DateTimeOffset.Now);
        var value = report["exception"]!["values"]![0]!["value"]!.GetValue<string>();
        Assert.Contains(@"%USERPROFILE%\AppData\Local\Programs\Murmur\whisper.dll", value);
        Assert.DoesNotContain("Jesse", value, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("fatal", report["level"]!.GetValue<string>());
    }

    [Fact] public void RootCauseComesFirstAndFramesAreInApp()
    {
        var error = Thrown(() => new InvalidOperationException("outer", new TimeoutException("inner")));
        var values = ErrorReport.CreateEvent(error, Info, true, "test", DateTimeOffset.Now)["exception"]!["values"]!.AsArray();
        Assert.Equal("System.TimeoutException", values[0]!["type"]!.GetValue<string>());
        Assert.Equal("System.InvalidOperationException", values[1]!["type"]!.GetValue<string>());
        var frames = values[1]!["stacktrace"]!["frames"]!.AsArray();
        Assert.Contains(frames, f => f!["function"]!.GetValue<string>().Contains("ErrorReportTests") && f["in_app"]!.GetValue<bool>());
    }

    [Fact] public void EnvelopeHasHeaderItemAndPayload()
    {
        var report = ErrorReport.CreateEvent(Thrown(() => new TimeoutException("slow")), Info, true, "test", DateTimeOffset.Now);
        var lines = Encoding.UTF8.GetString(ErrorReport.Envelope(report, DateTimeOffset.Now)).Split('\n');
        Assert.Equal(report["event_id"]!.GetValue<string>(), JsonNode.Parse(lines[0])!["event_id"]!.GetValue<string>());
        var item = JsonNode.Parse(lines[1])!;
        Assert.Equal("event", item["type"]!.GetValue<string>());
        Assert.Equal(Encoding.UTF8.GetByteCount(lines[2]), item["length"]!.GetValue<int>());
        Assert.Equal(report["event_id"]!.GetValue<string>(), JsonNode.Parse(lines[2])!["event_id"]!.GetValue<string>());
    }

    [Fact] public void SameProblemQueuesOnceAndQueueIsCapped()
    {
        var store = new ErrorReportStore(directory, limit: 3);
        Exception Same() => Thrown(() => new TimeoutException("same"));
        Assert.True(store.Save(ErrorReport.CreateEvent(Same(), Info, true, "test", DateTimeOffset.Now)));
        Assert.False(store.Save(ErrorReport.CreateEvent(Same(), Info, true, "test", DateTimeOffset.Now)));
        Assert.Single(store.Pending());
        Exception[] different = [Thrown(() => new IOException("a")), Thrown(() => new FormatException("b")),
            Thrown(() => new ArgumentException("c")), Thrown(() => new KeyNotFoundException("d"))];
        foreach (var error in different) store.Save(ErrorReport.CreateEvent(error, Info, true, "test", DateTimeOffset.Now));
        Assert.Equal(3, store.Pending().Count);
        store.DiscardAll();
        Assert.Empty(store.Pending());
    }

    [Fact] public async Task SendingDeliversThenClearsAndKeepsFailuresForLater()
    {
        var store = new ErrorReportStore(directory);
        store.Save(ErrorReport.CreateEvent(Thrown(() => new TimeoutException("x")), Info, true, "test", DateTimeOffset.Now));
        var dsn = SentryDsn.Parse("https://key@o1.ingest.sentry.io/2")!;

        var down = new Recorder(HttpStatusCode.ServiceUnavailable);
        Assert.Equal(1, await store.SendAllAsync(dsn, new HttpClient(down), "murmur-windows/0.1.3", default));
        Assert.Single(store.Pending());

        var up = new Recorder(HttpStatusCode.OK);
        Assert.Equal(0, await store.SendAllAsync(dsn, new HttpClient(up), "murmur-windows/0.1.3", default));
        Assert.Empty(store.Pending());
        Assert.Equal("https://o1.ingest.sentry.io/api/2/envelope/", up.Uri);
        Assert.Contains("sentry_key=key", up.Auth);
        Assert.Equal("application/x-sentry-envelope", up.ContentType);
    }

    private sealed class Recorder(HttpStatusCode status) : HttpMessageHandler
    {
        public string? Uri, Auth, ContentType;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Uri = request.RequestUri?.ToString();
            Auth = string.Join(",", request.Headers.GetValues("X-Sentry-Auth"));
            ContentType = request.Content?.Headers.ContentType?.MediaType;
            return Task.FromResult(new HttpResponseMessage(status));
        }
    }

    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
