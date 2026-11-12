using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Murmur.Windows.Services;

internal static class CleanupService
{
    public static async Task<string> CleanAsync(string text, string modelPath, CancellationToken token)
    {
        // Very long takes retain the original instead of risking context truncation.
        if (text.Length > 6000) return text;
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Cleanup", "Murmur.Cleanup.exe"))
        {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true, CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8
        };
        start.ArgumentList.Add(modelPath);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Cleanup could not start.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(90));
        using var registration = timeout.Token.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
        });
        var outputTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
        var errorTask = process.StandardError.ReadToEndAsync(timeout.Token);
        await process.StandardInput.WriteAsync(JsonSerializer.Serialize(text).AsMemory(), timeout.Token);
        process.StandardInput.Close();
        await process.WaitForExitAsync(timeout.Token);
        var output = await outputTask;
        await errorTask;
        if (process.ExitCode != 0) throw new InvalidOperationException("Cleanup could not finish.");
        var result = output.Split('\n').LastOrDefault(line => line.StartsWith("MURMUR_RESULT:", StringComparison.Ordinal));
        if (result is null) throw new InvalidDataException("Cleanup returned no text.");
        return TextProcessing.GuardCleanup(JsonSerializer.Deserialize<string>(result[14..]) ?? "", text);
    }
}
