namespace Murmur.Core;

public sealed record Settings
{
    public string ModelId { get; init; } = "base";
    public string Language { get; init; } = "auto";
    public string? MicrophoneId { get; init; }
    public int TriggerKey { get; init; } = 0xA3; // Right Ctrl; Fn is not exposed by Windows.
    public bool HandsFree { get; init; } = true;
    public bool RemoveFillers { get; init; } = true;
    public bool SmartCleanup { get; init; }
    public bool SaveHistory { get; init; } = true;
    public bool SoundEffects { get; init; }
    public bool LaunchAtLogin { get; init; }
    public string[] Vocabulary { get; init; } = [];

    public Settings Normalize() => this with
    {
        ModelId = ModelCatalog.Speech.Any(m => m.Id == ModelId) ? ModelId : "base",
        Language = Languages.Any(l => l.Code == Language) ? Language : "auto",
        TriggerKey = TriggerKeys.ContainsKey(TriggerKey) ? TriggerKey : 0xA3,
        Vocabulary = (Vocabulary ?? []).Where(w => !string.IsNullOrWhiteSpace(w))
            .Select(w => w.Trim()).Where(w => w.Length <= 80)
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToArray()
    };

    public static IReadOnlyDictionary<int, string> TriggerKeys { get; } = new Dictionary<int, string>
    {
        [0xA3] = "Right Ctrl", [0xA1] = "Right Shift", [0x77] = "F8", [0x78] = "F9"
    };

    public static (string Code, string Name)[] Languages { get; } =
    [
        ("auto", "Detect automatically"), ("en", "English"), ("pt", "Português"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"),
        ("nl", "Nederlands"), ("ja", "日本語"), ("ko", "한국어"), ("zh", "中文"),
        ("hi", "हिन्दी"), ("ar", "العربية"), ("ru", "Русский"), ("uk", "Українська")
    ];
}

public sealed record Transcript(Guid Id, DateTimeOffset CreatedAt, string Text, string Original, double Seconds);

public static class AppPaths
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Murmur");
    public static string Models => Path.Combine(Root, "Models");
}
