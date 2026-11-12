using Murmur.Core;
using Xunit;

namespace Murmur.Tests;

public class SpeechIntegrationTests
{
    [Fact, Trait("Category", "Integration")]
    public async Task NativeDecodeCanBeCanceledAndEngineReused()
    {
        var directory = Environment.GetEnvironmentVariable("MURMUR_TEST_MODELS") ?? throw new InvalidOperationException("Set MURMUR_TEST_MODELS.");
        var wav = Environment.GetEnvironmentVariable("MURMUR_TEST_WAV") ?? throw new InvalidOperationException("Set MURMUR_TEST_WAV.");
        using var http = new HttpClient();
        using var engine = new SpeechEngine(new ModelDownloader(http, directory));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
        await engine.PrepareAsync(ModelCatalog.Find("tiny"), timeout.Token);
        var samples = ReadPcm16(wav);
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        var longTake = Enumerable.Range(0, 20).SelectMany(_ => samples).ToArray();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => engine.TranscribeAsync(longTake, new() { ModelId = "tiny", Language = "en" }, cancel.Token));
        var text = await engine.TranscribeAsync(samples, new() { ModelId = "tiny", Language = "en" }, timeout.Token);
        Assert.Contains("country", text, StringComparison.OrdinalIgnoreCase);
    }

    // Explicit opt-in; the build runs these on Windows with the same native DLLs
    // as the shipped app and the upstream whisper.cpp JFK speech sample.
    [Fact, Trait("Category", "Integration")]
    public async Task ActualNativeEngineTranscribesSpeech()
    {
        var modelDirectory = Environment.GetEnvironmentVariable("MURMUR_TEST_MODELS") ?? throw new InvalidOperationException("Set MURMUR_TEST_MODELS for integration tests.");
        var wav = Environment.GetEnvironmentVariable("MURMUR_TEST_WAV") ?? throw new InvalidOperationException("Set MURMUR_TEST_WAV for integration tests.");
        using var http = new HttpClient();
        using var engine = new SpeechEngine(new ModelDownloader(http, modelDirectory));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
        var text = await engine.TranscribeAsync(ReadPcm16(wav), new() { ModelId = "tiny", Language = "en" }, timeout.Token);
        Assert.Contains("country", text, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("ask", text, StringComparison.OrdinalIgnoreCase);
    }
    private static float[] ReadPcm16(string path)
    {
        using var reader = new BinaryReader(File.OpenRead(path));
        Assert.Equal("RIFF", new string(reader.ReadChars(4))); reader.ReadInt32();
        Assert.Equal("WAVE", new string(reader.ReadChars(4)));
        while (reader.BaseStream.Position < reader.BaseStream.Length)
        {
            var id = new string(reader.ReadChars(4)); var length = reader.ReadInt32();
            var end = reader.BaseStream.Position + length + (length & 1);
            if (id == "fmt ")
            {
                Assert.Equal(1, reader.ReadInt16()); Assert.Equal(1, reader.ReadInt16()); Assert.Equal(16000, reader.ReadInt32());
                reader.ReadInt32(); reader.ReadInt16(); Assert.Equal(16, reader.ReadInt16());
            }
            if (id == "data")
            {
                var samples = new float[length / 2];
                for (var i = 0; i < samples.Length; i++) samples[i] = reader.ReadInt16() / 32768f;
                return samples;
            }
            reader.BaseStream.Position = end;
        }
        throw new InvalidDataException("No PCM data in test fixture.");
    }
}
