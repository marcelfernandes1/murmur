namespace Murmur.Core;

public sealed record ModelInfo(string Id, string Name, string FileName, string Repository, long Bytes, string Sha256)
{
    public Uri DownloadUri => new($"https://huggingface.co/{Repository}/resolve/main/{FileName}?download=true");
    public override string ToString() => Name;
}

// Pins match Murmur for macOS's ModelManifest; models are verified before parsing.
public static class ModelCatalog
{
    public static IReadOnlyList<ModelInfo> Speech { get; } =
    [
        new("tiny", "Quick · 77 MB", "ggml-tiny.bin", "ggerganov/whisper.cpp", 77691713,
            "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        new("base", "Everyday · 148 MB", "ggml-base.bin", "ggerganov/whisper.cpp", 147951465,
            "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        new("small", "Accurate · 488 MB", "ggml-small.bin", "ggerganov/whisper.cpp", 487601967,
            "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        new("turbo", "Most accurate · 574 MB", "ggml-large-v3-turbo-q5_0.bin", "ggerganov/whisper.cpp", 574041195,
            "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
    ];
    public static ModelInfo Cleanup { get; } = new("cleanup", "Smart cleanup · 986 MB",
        "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf", "bartowski/Qwen2.5-1.5B-Instruct-GGUF", 986048768,
        "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370");
    public static ModelInfo Find(string id) => Speech.Single(m => m.Id == id);
}
