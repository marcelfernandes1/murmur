using System.Text.Json;

namespace Murmur.Core;

/// Atomic replacement keeps a failed save from destroying the last good copy.
public sealed class JsonStore<T>(string path, Func<T> defaultValue)
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public T Load()
    {
        if (!File.Exists(path)) return defaultValue();
        return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options)
            ?? throw new InvalidDataException($"The saved file is empty: {Path.GetFileName(path)}");
    }

    public void Save(T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, value, Options);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
