using Murmur.Core;
using Xunit;

namespace Murmur.Tests;

public class SessionTests
{
    [Fact] public void PushToTalkCommitsOnceDespiteKeyRepeat()
    {
        var session = new RecordingSession();
        Assert.Equal(SessionAction.Start, session.Press());
        Assert.Equal(SessionAction.None, session.Press());
        Assert.Equal(SessionAction.Commit, session.Release());
        Assert.Equal(SessionAction.None, session.Release());
        Assert.Equal(SessionAction.None, session.Press());
        Assert.Equal(SessionPhase.Transcribing, session.Phase);
    }
    [Fact] public void HandsFreeSurvivesReleaseAndCommitsOnNextPress()
    {
        var session = new RecordingSession();
        session.Press();
        Assert.Equal(SessionAction.Lock, session.Lock());
        Assert.Equal(SessionAction.None, session.Release());
        Assert.Equal(SessionAction.Commit, session.Press());
        Assert.Equal(SessionAction.None, session.Release());
    }
    [Fact] public void CanceledResultCannotDeliverOrResetANewerSession()
    {
        var session = new RecordingSession();
        session.Press(); session.Release();
        var old = session.Generation;
        session.Cancel(); session.Press();
        session.Finish(old);
        Assert.False(session.IsCurrent(old));
        Assert.Equal(SessionPhase.Recording, session.Phase);
        session.Release();
        Assert.True(session.IsCurrent(session.Generation));
    }
    [Theory]
    [InlineData(0, 50, 0, CaptureOutcome.AccidentalTap)]
    [InlineData(0, 1000, 0, CaptureOutcome.NoAudio)]
    [InlineData(48000, 3000, 0, CaptureOutcome.NoSignal)]
    [InlineData(1600, 500, 0.0006f, CaptureOutcome.Transcribe)]
    [InlineData(16000, 1000, 0.0033f, CaptureOutcome.Transcribe)]
    public void QuietSpeechIsNotRejected(int count, int milliseconds, float level, CaptureOutcome expected)
    {
        Assert.Equal(expected, CapturePolicy.Evaluate(Enumerable.Repeat(level, count).ToArray(), TimeSpan.FromMilliseconds(milliseconds)));
    }
}
