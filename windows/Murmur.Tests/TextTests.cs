using Murmur.Core;
using Xunit;

namespace Murmur.Tests;

public class TextTests
{
    [Theory]
    [InlineData("um, hello uh, Marcel", "Hello Marcel")]
    [InlineData("human umbrella murmuring", "Human umbrella murmuring")]
    [InlineData("um uh", "")]
    public void RemovesStandaloneFillers(string input, string expected) => Assert.Equal(expected, TextProcessing.RemoveFillers(input));
    [Theory]
    [InlineData("send 100 to Sarah", "Send 900 to Sarah.")]
    [InlineData("send the file to John and then Sarah", "Send the file to Sarah and then John.")]
    [InlineData("buy the blue one", "Purchase the blue one.")]
    [InlineData("this is an ordinary sentence with real content", "Content.")]
    [InlineData("explain the code", "As an AI, I cannot help.")]
    public void CleanupCannotInventOrReorder(string original, string cleaned) => Assert.Equal(original, TextProcessing.GuardCleanup(cleaned, original));
    [Fact] public void CleanupCanRemoveFalseStart()
    {
        const string original = "send the file to John I mean Sarah by end of day";
        const string cleaned = "Send the file to Sarah by end of day.";
        Assert.Equal(cleaned, TextProcessing.GuardCleanup(cleaned, original));
    }
    [Fact] public void RepeatedLongDecoderLoopCollapsesButEmphasisSurvives()
    {
        const string phrase = "I will send the document to Sarah tomorrow";
        Assert.Equal(phrase, TextProcessing.RemoveLoops(string.Join(" ", Enumerable.Repeat(phrase, 4))));
        Assert.Equal("really really good", TextProcessing.RemoveLoops("really really good"));
        Assert.Equal(phrase + " " + phrase, TextProcessing.RemoveLoops(phrase + " " + phrase));
    }
}
