namespace Murmur.Core;

public enum SessionPhase { Idle, Recording, Locked, Transcribing }
public enum SessionAction { None, Start, Lock, Commit, Cancel }

/// All input sources share one state machine. Repeat key-downs cannot start a
/// second recording; cancellation invalidates every pending delivery ticket.
public sealed class RecordingSession
{
    public SessionPhase Phase { get; private set; }
    public long Generation { get; private set; }
    public bool IsCapturing => Phase is SessionPhase.Recording or SessionPhase.Locked;
    private bool triggerHeld;

    public SessionAction Press()
    {
        if (triggerHeld) return SessionAction.None;
        triggerHeld = true;
        if (Phase == SessionPhase.Locked) return Commit();
        if (Phase != SessionPhase.Idle) return SessionAction.None;
        Generation++;
        Phase = SessionPhase.Recording;
        return SessionAction.Start;
    }
    public SessionAction Release()
    {
        triggerHeld = false;
        return Phase == SessionPhase.Recording ? Commit() : SessionAction.None;
    }
    public SessionAction Lock()
    {
        if (Phase != SessionPhase.Recording) return SessionAction.None;
        Phase = SessionPhase.Locked;
        return SessionAction.Lock;
    }
    public SessionAction Commit()
    {
        if (!IsCapturing) return SessionAction.None;
        Phase = SessionPhase.Transcribing;
        return SessionAction.Commit;
    }
    public SessionAction Cancel()
    {
        if (Phase == SessionPhase.Idle) return SessionAction.None;
        Generation++;
        Phase = SessionPhase.Idle;
        return SessionAction.Cancel;
    }
    public bool IsCurrent(long generation) => generation == Generation && Phase == SessionPhase.Transcribing;
    public void Finish(long generation) { if (generation == Generation) Phase = SessionPhase.Idle; }
}

public enum CaptureOutcome { AccidentalTap, NoAudio, NoSignal, Transcribe }
public static class CapturePolicy
{
    public static CaptureOutcome Evaluate(float[] samples, TimeSpan held)
    {
        if (samples.Length < 1600)
            return held.TotalMilliseconds < 400 ? CaptureOutcome.AccidentalTap : CaptureOutcome.NoAudio;
        // Do not classify quiet speech as silence based on an estimated noise floor.
        return samples.Any(s => Math.Abs(s) >= 0.0005f) ? CaptureOutcome.Transcribe : CaptureOutcome.NoSignal;
    }
}
