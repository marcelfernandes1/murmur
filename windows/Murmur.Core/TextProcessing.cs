using System.Globalization;
using System.Text.RegularExpressions;

namespace Murmur.Core;

public static partial class TextProcessing
{
    [GeneratedRegex(@"(?i)\b(um+|umm+|uh+|uhm+|hmm+|mhm+|erm+|er|ah+)\b[,]?")]
    private static partial Regex Fillers();
    [GeneratedRegex(@"[^\p{L}\p{N}]+")]
    private static partial Regex TokenBoundary();
    [GeneratedRegex(@"[\t ]{2,}")]
    private static partial Regex Spaces();
    [GeneratedRegex(@" +([.,!?;:])")]
    private static partial Regex Punctuation();
    public static string Tidy(string text) => Punctuation().Replace(Spaces().Replace(text, " "), "$1").Trim();
    public static string RemoveFillers(string text)
    {
        var result = Tidy(Fillers().Replace(text, "")).TrimStart(',', ' ');
        return result.Length == 0 ? result : char.ToUpper(result[0], CultureInfo.CurrentCulture) + result[1..];
    }
    private static string[] Tokens(string text) => TokenBoundary().Split(text.ToLowerInvariant()).Where(t => t.Length > 0).ToArray();

    public static string GuardCleanup(string cleaned, string original)
    {
        cleaned = cleaned.Trim();
        if (cleaned.Length == 0) return original;
        var source = Tokens(original);
        var output = Tokens(cleaned);
        if (output.Length > source.Length * 1.5 + 8) return original;
        // A cleanup may remove fillers but may not invent, reorder, or change any
        // words or digits. Number conversion is intentionally conservative.
        var index = 0;
        foreach (var token in source)
            if (index < output.Length && token == output[index]) index++;
        if (index != output.Length) return original;
        if (source.Length >= 6 && output.Length < source.Length / 3) return original;
        return cleaned;
    }

    public static string RemoveLoops(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var normalized = words.Select(w => string.Join("", Tokens(w))).ToArray();
        var result = new List<string>();
        for (var i = 0; i < words.Length;)
        {
            var consumed = 0;
            for (var size = Math.Min(30, (words.Length - i) / 3); size >= 5; size--)
            {
                var repeats = 1;
                while (i + size * (repeats + 1) <= words.Length &&
                    normalized.AsSpan(i, size).SequenceEqual(normalized.AsSpan(i + size * repeats, size))) repeats++;
                if (repeats < 3 || size * repeats < 18) continue;
                result.AddRange(words.Skip(i).Take(size));
                consumed = size * repeats;
                break;
            }
            if (consumed == 0) { result.Add(words[i]); consumed = 1; }
            i += consumed;
        }
        return Tidy(string.Join(" ", result));
    }
}
