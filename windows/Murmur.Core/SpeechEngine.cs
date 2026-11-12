using Whisper.net;

namespace Murmur.Core;

public sealed class SpeechEngine(ModelDownloader downloader) : IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private WhisperFactory? factory;
    private string? loadedModel;
    public async Task PrepareAsync(ModelInfo model, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try { await LoadAsync(model, token); }
        finally { gate.Release(); }
    }

    private async Task LoadAsync(ModelInfo model, CancellationToken token)
    {
        if (loadedModel == model.Id && factory is not null) return;
        // Model files are untrusted until their complete build-pinned hash passes.
        var path = await downloader.EnsureAsync(model, null, token);
        factory?.Dispose();
        factory = null;
        loadedModel = null;
        factory = await Task.Run(() => WhisperFactory.FromPath(path), token);
        loadedModel = model.Id;
    }

    public async Task<string> TranscribeAsync(float[] samples, Settings settings, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            await LoadAsync(ModelCatalog.Find(settings.ModelId), token);
            return await Task.Run(async () =>
            {
                var builder = factory!.CreateBuilder().WithLanguage(settings.Language)
                    .WithThreads(Math.Max(1, Math.Min(8, Environment.ProcessorCount - 1)))
                    .WithNoContext().WithTemperature(0).WithNoSpeechThreshold(0.6f);
                // Short/quiet clips are especially prone to vocabulary prompt echo.
                var rms = Math.Sqrt(samples.Select(s => (double)s * s).Average());
                if (samples.Length >= 32000 && rms >= 0.005 && settings.Vocabulary.Length > 0)
                    builder.WithPrompt(string.Join(", ", settings.Vocabulary).Truncate(800));
                // Cancellation ends the async enumerator before the native worker
                // necessarily exits. Await teardown before reusing/freeing its model.
                await using var processor = builder.Build();
                var segments = new List<string>();
                await foreach (var segment in processor.ProcessAsync(samples, token)) segments.Add(segment.Text.Trim());
                token.ThrowIfCancellationRequested();
                return TextProcessing.RemoveLoops(string.Join(" ", segments));
            }, token);
        }
        finally { gate.Release(); }
    }

    // Called only after the controller has drained its in-flight task on shutdown.
    public void Dispose() { factory?.Dispose(); gate.Dispose(); }
}

internal static class StringExtensions
{
    public static string Truncate(this string value, int length) => value.Length <= length ? value : value[..length];
}
