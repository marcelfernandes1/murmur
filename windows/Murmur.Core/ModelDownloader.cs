using System.Security.Cryptography;

namespace Murmur.Core;

public sealed class ModelDownloader(HttpClient http, string directory)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public string PathFor(ModelInfo model) => Path.Combine(directory, model.FileName);
    public bool IsDownloaded(ModelInfo model) => File.Exists(PathFor(model)) && new FileInfo(PathFor(model)).Length == model.Bytes;

    public async Task<string> EnsureAsync(ModelInfo model, IProgress<double>? progress, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            Directory.CreateDirectory(directory);
            var destination = PathFor(model);
            if (IsDownloaded(model) && await VerifyAsync(destination, model, token)) return destination;
            var partial = destination + ".partial";
            try
            {
                using var response = await http.GetAsync(model.DownloadUri, HttpCompletionOption.ResponseHeadersRead, token);
                response.EnsureSuccessStatusCode();
                await using var input = await response.Content.ReadAsStreamAsync(token);
                await using (var output = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 131072, true))
                {
                    var buffer = new byte[131072];
                    long total = 0;
                    int count;
                    while ((count = await input.ReadAsync(buffer, token)) != 0)
                    {
                        total += count;
                        if (total > model.Bytes) throw new InvalidDataException("The model download has the wrong size. Please try again.");
                        await output.WriteAsync(buffer.AsMemory(0, count), token);
                        progress?.Report((double)total / model.Bytes);
                    }
                }
                if (!await VerifyAsync(partial, model, token))
                    throw new InvalidDataException("The model download did not pass verification. Please try again.");
                File.Move(partial, destination, overwrite: true);
                return destination;
            }
            finally { if (File.Exists(partial)) File.Delete(partial); }
        }
        finally { gate.Release(); }
    }

    public static async Task<bool> VerifyAsync(string path, ModelInfo model, CancellationToken token)
    {
        if (new FileInfo(path).Length != model.Bytes) return false;
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, token);
        return Convert.ToHexString(hash).Equals(model.Sha256, StringComparison.OrdinalIgnoreCase);
    }
}
