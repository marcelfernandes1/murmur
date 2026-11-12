using System.Net;
using System.Security.Cryptography;
using Murmur.Core;
using Xunit;

namespace Murmur.Tests;

public sealed class StorageTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "murmur-tests-" + Guid.NewGuid());
    private static readonly byte[] ModelBytes = "a model fixture"u8.ToArray();
    private static readonly ModelInfo Model = new("test", "Test", "fixture.bin", "unused/test", ModelBytes.Length, Convert.ToHexString(SHA256.HashData(ModelBytes)));

    [Fact] public async Task DownloadVerifiesBeforePromotionAndReusesCache()
    {
        var handler = new FakeHandler(ModelBytes);
        using var client = new HttpClient(handler);
        var downloader = new ModelDownloader(client, directory);
        var path = await downloader.EnsureAsync(Model, null, default);
        Assert.Equal(ModelBytes, await File.ReadAllBytesAsync(path));
        await downloader.EnsureAsync(Model, null, default);
        Assert.Equal(1, handler.Requests);
    }
    [Fact] public async Task SameSizeCorruptionIsNeverLoaded()
    {
        Directory.CreateDirectory(directory);
        await File.WriteAllBytesAsync(Path.Combine(directory, Model.FileName), new byte[ModelBytes.Length]);
        var handler = new FakeHandler(ModelBytes);
        using var client = new HttpClient(handler);
        var path = await new ModelDownloader(client, directory).EnsureAsync(Model, null, default);
        Assert.Equal(ModelBytes, await File.ReadAllBytesAsync(path));
        Assert.Equal(1, handler.Requests);
    }
    [Fact] public async Task BadDownloadNeverBecomesACachedModel()
    {
        using var client = new HttpClient(new FakeHandler(new byte[ModelBytes.Length]));
        var downloader = new ModelDownloader(client, directory);
        await Assert.ThrowsAsync<InvalidDataException>(() => downloader.EnsureAsync(Model, null, default));
        Assert.False(File.Exists(downloader.PathFor(Model)));
        Assert.Empty(Directory.GetFiles(directory));
    }
    [Fact] public async Task CanceledDownloadDoesNotLeavePartialFiles()
    {
        using var cancellation = new CancellationTokenSource();
        using var client = new HttpClient(new FakeHandler(ModelBytes, () => cancellation.Cancel()));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new ModelDownloader(client, directory).EnsureAsync(Model, null, cancellation.Token));
        Assert.Empty(Directory.GetFiles(directory));
    }
    [Fact] public void StoreRoundTripsUnicodeWithoutLeavingTemporaryFiles()
    {
        var store = new JsonStore<Settings>(Path.Combine(directory, "settings.json"), () => new());
        store.Save(new() { Language = "pt", Vocabulary = ["São Paulo", "Murmur", "日本語"] });
        Assert.Equal("São Paulo", store.Load().Vocabulary[0]);
        store.Save(store.Load() with { SaveHistory = false });
        Assert.False(store.Load().SaveHistory);
        Assert.Single(Directory.GetFiles(directory));
    }
    [Fact] public void InvalidStoredJsonDoesNotSilentlyReset()
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "settings.json");
        File.WriteAllText(path, "not json");
        Assert.Throws<System.Text.Json.JsonException>(() => new JsonStore<Settings>(path, () => new()).Load());
        Assert.Equal("not json", File.ReadAllText(path));
    }
    [Fact] public void InvalidPreferencesFallBackAndVocabularyIsBounded()
    {
        var value = new Settings { ModelId = "unknown", Language = "xx", TriggerKey = -1, Vocabulary = [" Murmur ", "murmur", "", new string('a', 81)] }.Normalize();
        Assert.Equal("base", value.ModelId); Assert.Equal("auto", value.Language); Assert.Equal(0xA3, value.TriggerKey);
        Assert.Equal(new[] { "Murmur" }, value.Vocabulary);
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    private sealed class FakeHandler(byte[] bytes, Action? onRequest = null) : HttpMessageHandler
    {
        public int Requests { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Requests++; onRequest?.Invoke(); token.ThrowIfCancellationRequested();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });
        }
    }
}
