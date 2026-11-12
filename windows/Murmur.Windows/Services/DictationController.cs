using System.Diagnostics;
using System.Net.Http;
using System.Windows.Threading;
using Microsoft.Win32;
using Murmur.Windows.Views;

namespace Murmur.Windows.Services;

internal sealed class DictationController
{
    private readonly Dispatcher dispatcher;
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(30) };
    private readonly JsonStore<Settings> settingsStore = new(Path.Combine(AppPaths.Root, "settings.json"), () => new());
    private readonly JsonStore<List<Transcript>> historyStore = new(Path.Combine(AppPaths.Root, "history.json"), () => []);
    private readonly RecordingSession session = new();
    private readonly AudioRecorder recorder = new();
    private readonly GlobalHotkey hotkey;
    private readonly SpeechEngine engine;
    private readonly RecordingOverlay overlay = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private CancellationTokenSource? operationCancellation;
    private Task operation = Task.CompletedTask;
    private DeliveryTarget? target;
    private Settings? recordingSettings;
    private long startedAt;
    private float[]? retrySamples;
    private Settings? retrySettings;
    private bool preparing;
    private bool closing;
    private DateTimeOffset hideOverlayAt = DateTimeOffset.MaxValue;

    public ModelDownloader Models { get; }
    public Settings Settings { get; private set; } = new();
    public List<Transcript> History { get; private set; } = [];
    public string Status { get; private set; } = "Download your speech model to get started.";
    public double DownloadProgress { get; private set; }
    public bool Busy => preparing || session.Phase != SessionPhase.Idle || !operation.IsCompleted;
    public bool CanRetry => retrySamples is not null && !Busy;
    public bool IsRecording => session.IsCapturing;
    public bool IsPreparing => preparing;
    public event Action? Changed;

    public DictationController(Dispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        Settings = LoadPreservingCorruptFile(settingsStore, "settings.json", new Settings()).Normalize();
        History = LoadPreservingCorruptFile(historyStore, "history.json", new List<Transcript>()).Take(500).ToList();
        Models = new(http, AppPaths.Models);
        engine = new(Models);
        hotkey = new(dispatcher) { TriggerKey = Settings.TriggerKey };
        hotkey.Pressed += () =>
        {
            if (preparing || closing || session.Phase == SessionPhase.Idle && !operation.IsCompleted) return;
            Dispatch(session.Press());
        };
        hotkey.Released += () => Dispatch(session.Release());
        hotkey.LockRequested += () => Dispatch(session.Lock());
        hotkey.CancelRequested += Cancel;
        overlay.Done += () => Dispatch(session.Commit());
        overlay.Cancel += Cancel;
        recorder.Ended += error => dispatcher.BeginInvoke(() =>
        {
            if (!session.IsCapturing) return;
            Cancel();
            SetStatus("The microphone disconnected. Check your microphone and try again.", show: true);
        });
        timer.Tick += (_, _) => Tick();
        timer.Start();
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    private T LoadPreservingCorruptFile<T>(JsonStore<T> store, string fileName, T fallback)
    {
        try { return store.Load(); }
        catch (Exception e) when (e is IOException or System.Text.Json.JsonException or UnauthorizedAccessException)
        {
            var path = Path.Combine(AppPaths.Root, fileName);
            // Keep the actual broken file available for recovery; do not overwrite it.
            if (File.Exists(path)) File.Move(path, path + ".recovery-" + DateTime.UtcNow.ToString("yyyyMMddHHmmssfff"));
            Status = "A saved file could not be read. A recovery copy is in your Murmur data folder.";
            return fallback;
        }
    }

    public void Initialize()
    {
        if (Models.IsDownloaded(ModelCatalog.Find(Settings.ModelId))) PrepareModels();
        else Changed?.Invoke();
    }

    public void SaveSettings(Settings value)
    {
        if (Busy) throw new InvalidOperationException("Finish or cancel your dictation before changing settings.");
        var normalized = value.Normalize();
        LoginStartup.SetEnabled(normalized.LaunchAtLogin);
        try { settingsStore.Save(normalized); }
        catch { LoginStartup.SetEnabled(Settings.LaunchAtLogin); throw; }
        Settings = normalized;
        hotkey.TriggerKey = Settings.TriggerKey;
        SetStatus("Settings saved.");
        if (Models.IsDownloaded(ModelCatalog.Find(Settings.ModelId))) PrepareModels();
        else SetStatus("Download your selected speech model to start dictating.");
    }

    public void PrepareModels()
    {
        if (Busy || closing) return;
        preparing = true;
        DownloadProgress = 0;
        operationCancellation = new();
        operation = PrepareAsync(operationCancellation.Token);
    }

    private async Task PrepareAsync(CancellationToken token)
    {
        try
        {
            var speech = ModelCatalog.Find(Settings.ModelId);
            SetStatus(Models.IsDownloaded(speech) ? "Checking your speech model…" : "Downloading your speech model…");
            await Models.EnsureAsync(speech, new Progress<double>(p => { DownloadProgress = p; Changed?.Invoke(); }), token);
            if (Settings.SmartCleanup)
            {
                SetStatus("Preparing smart cleanup…");
                await Models.EnsureAsync(ModelCatalog.Cleanup, new Progress<double>(p => { DownloadProgress = p; Changed?.Invoke(); }), token);
            }
            SetStatus("Loading your speech model…");
            await engine.PrepareAsync(speech, token);
            SetStatus($"Ready. Hold {Settings.TriggerKeys[Settings.TriggerKey]} to talk.");
        }
        catch (OperationCanceledException) { SetStatus("Setup paused. Select Download & prepare to try again."); }
        catch (Exception e) { SetStatus(FriendlyError(e, "Model setup could not finish. Check your connection and free disk space, then try again.")); }
        finally
        {
            preparing = false;
            operationCancellation?.Dispose(); operationCancellation = null;
            _ = dispatcher.BeginInvoke(() => Changed?.Invoke());
        }
    }

    private void Dispatch(SessionAction action)
    {
        if (closing) return;
        switch (action)
        {
            case SessionAction.Start:
                if (!Models.IsDownloaded(ModelCatalog.Find(Settings.ModelId)))
                {
                    session.Cancel();
                    SetStatus("Open Murmur and download your speech model first.", show: true);
                    break;
                }
                retrySamples = null; retrySettings = null;
                target = TextDelivery.CaptureTarget();
                recordingSettings = Settings;
                startedAt = Stopwatch.GetTimestamp();
                try
                {
                    recorder.Start(Settings.MicrophoneId);
                    operationCancellation = new();
                    SetStatus("Listening…", show: true);
                    if (Settings.SoundEffects) System.Media.SystemSounds.Asterisk.Play();
                }
                catch (Exception e)
                {
                    session.Cancel();
                    SetStatus(e is UnauthorizedAccessException
                        ? "Windows blocked microphone access. Open Microphone privacy and allow desktop apps to use your microphone."
                        : FriendlyError(e, "Microphone unavailable. Check Windows microphone privacy and select an available microphone."), show: true);
                }
                break;
            case SessionAction.Lock: SetStatus("Hands-free. Press your shortcut to finish.", show: true); break;
            case SessionAction.Commit:
                operation = CommitAsync(session.Generation, operationCancellation!.Token);
                break;
        }
        RefreshHotkey();
        Changed?.Invoke();
    }

    private async Task CommitAsync(long generation, CancellationToken token)
    {
        var held = Stopwatch.GetElapsedTime(startedAt);
        SetStatus("Transcribing on your PC…", show: true);
        try
        {
            var samples = await recorder.StopAsync();
            token.ThrowIfCancellationRequested();
            switch (CapturePolicy.Evaluate(samples, held))
            {
                case CaptureOutcome.AccidentalTap: SetStatus("Ready."); overlay.Hide(); return;
                case CaptureOutcome.NoAudio: SetStatus("No audio arrived. Check your microphone and try again.", show: true); return;
                case CaptureOutcome.NoSignal: SetStatus("Your microphone was silent. Check mute and try again.", show: true); return;
            }
            retrySamples = samples; retrySettings = recordingSettings;
            await TranscribeAndDeliverAsync(samples, recordingSettings!, target!, generation, token);
        }
        catch (OperationCanceledException) { SetStatus("Dictation canceled."); }
        catch (Exception e) { SetStatus(FriendlyError(e, "Dictation could not finish. Open Murmur to retry the recording."), show: true); }
        finally { Finish(generation); }
    }

    private async Task TranscribeAndDeliverAsync(float[] samples, Settings snapshot, DeliveryTarget destination, long generation, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromMinutes(5));
        string original;
        try { original = await engine.TranscribeAsync(samples, snapshot, timeout.Token); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new TimeoutException("Transcription took too long. Try a faster speech model."); }
        if (string.IsNullOrWhiteSpace(original))
        {
            retrySamples = null; retrySettings = null;
            SetStatus("No words recognized. Try again a little closer to your microphone.", show: true);
            return;
        }
        var text = snapshot.RemoveFillers ? TextProcessing.RemoveFillers(original) : original;
        var cleanupFailed = false;
        if (snapshot.SmartCleanup && !string.IsNullOrWhiteSpace(text))
        {
            try
            {
                if (!Models.IsDownloaded(ModelCatalog.Cleanup)) throw new InvalidOperationException();
                // Verify the cleanup file again before handing it to a native parser.
                if (!await ModelDownloader.VerifyAsync(Models.PathFor(ModelCatalog.Cleanup), ModelCatalog.Cleanup, token)) throw new InvalidDataException();
                SetStatus("Tidying your words on your PC…", show: true);
                text = await CleanupService.CleanAsync(text, Models.PathFor(ModelCatalog.Cleanup), token);
            }
            catch (Exception) when (!token.IsCancellationRequested) { cleanupFailed = true; }
        }
        if (!session.IsCurrent(generation)) return;
        token.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(text)) { SetStatus("No words left after removing fillers."); return; }
        var saved = true;
        if (snapshot.SaveHistory)
        {
            History.Insert(0, new(Guid.NewGuid(), DateTimeOffset.Now, text, original, samples.Length / 16000d));
            if (History.Count > 500) History.RemoveRange(500, History.Count - 500);
            try { historyStore.Save(History); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { saved = false; }
        }
        string message;
        try { message = await TextDelivery.DeliverAsync(text, destination, token); }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Keep even a history-disabled result recoverable for this app session.
            if (!snapshot.SaveHistory) History.Insert(0, new(Guid.NewGuid(), DateTimeOffset.Now, text, original, samples.Length / 16000d));
            message = "Clipboard busy. Open History and copy your text.";
        }
        retrySamples = null; retrySettings = null;
        if (cleanupFailed) message += " Cleanup unavailable; kept your words.";
        if (!saved) message += " History could not save to disk; copy your text before quitting.";
        SetStatus(message, show: true);
    }

    public void Retry()
    {
        if (!CanRetry || retrySettings is null) return;
        session.Press(); session.Release();
        operationCancellation = new();
        operation = RetryAsync(session.Generation, retrySamples!, retrySettings, operationCancellation.Token);
        RefreshHotkey();
    }
    private async Task RetryAsync(long generation, float[] samples, Settings snapshot, CancellationToken token)
    {
        SetStatus("Retrying on your PC…", show: true);
        try
        {
            // Retrying from the app must never paste into an old target.
            await TranscribeAndDeliverAsync(samples, snapshot, new(0, 0, 0), generation, token);
        }
        catch (OperationCanceledException) { SetStatus("Dictation canceled."); }
        catch (Exception e) { SetStatus(FriendlyError(e, "Still unable to transcribe. Try a smaller model or restart Murmur."), show: true); }
        finally { Finish(generation); }
    }

    public void Cancel()
    {
        var capturing = session.IsCapturing;
        session.Cancel();
        operationCancellation?.Cancel();
        retrySamples = null; retrySettings = null;
        if (capturing) operation = DiscardAsync();
        SetStatus("Canceled.");
        overlay.Hide();
        RefreshHotkey();
    }
    private async Task DiscardAsync()
    {
        try { await recorder.StopAsync(); }
        catch (Exception) { /* Device teardown failure must not prevent cancel. */ }
        finally
        {
            operationCancellation?.Dispose(); operationCancellation = null;
            _ = dispatcher.BeginInvoke(() => Changed?.Invoke());
        }
    }
    private void Finish(long generation)
    {
        session.Finish(generation);
        operationCancellation?.Dispose(); operationCancellation = null;
        RefreshHotkey();
        hideOverlayAt = DateTimeOffset.Now.AddSeconds(5);
        dispatcher.BeginInvoke(() => Changed?.Invoke());
    }
    private void RefreshHotkey()
    {
        hotkey.CanLock = session.Phase == SessionPhase.Recording && Settings.HandsFree;
        hotkey.CanCancel = session.Phase != SessionPhase.Idle;
    }
    private void Tick()
    {
        if (session.IsCapturing)
        {
            var elapsed = Stopwatch.GetElapsedTime(startedAt);
            overlay.UpdateLevel(recorder.Level, elapsed, session.Phase == SessionPhase.Locked);
            if (elapsed >= TimeSpan.FromMinutes(10)) Dispatch(session.Commit());
        }
        if (DateTimeOffset.Now >= hideOverlayAt) { overlay.Hide(); hideOverlayAt = DateTimeOffset.MaxValue; }
    }
    private void SetStatus(string message, bool show = false)
    {
        Status = message;
        if (show || overlay.IsVisible)
        {
            overlay.SetMessage(message, session.IsCapturing, session.Phase == SessionPhase.Locked);
            if (show) overlay.Reveal();
            hideOverlayAt = session.Phase == SessionPhase.Idle ? DateTimeOffset.Now.AddSeconds(6) : DateTimeOffset.MaxValue;
        }
        Changed?.Invoke();
    }
    public void ClearHistory()
    {
        historyStore.Save([]);
        History.Clear();
        Changed?.Invoke();
    }
    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock) dispatcher.BeginInvoke(Cancel);
    }
    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) dispatcher.BeginInvoke(Cancel);
    }
    private static string FriendlyError(Exception e, string fallback) => e switch
    {
        DllNotFoundException or BadImageFormatException => "Speech runtime unavailable. Install Microsoft Visual C++ 2015–2022 (x64), then restart Murmur.",
        InvalidDataException => "The model file could not be verified. Download it again from Murmur.",
        TimeoutException => "The operation took too long. Try again with the Quick speech model.",
        _ => fallback
    };
    public async Task ShutdownAsync()
    {
        closing = true;
        Cancel();
        timer.Stop(); hotkey.Dispose();
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        try { await operation.WaitAsync(TimeSpan.FromSeconds(8)); }
        catch (Exception) { }
        if (operation.IsCompleted) { engine.Dispose(); recorder.Dispose(); http.Dispose(); }
        overlay.Close();
    }
}
