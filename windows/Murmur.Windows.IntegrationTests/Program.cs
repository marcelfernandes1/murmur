using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Threading;
using Murmur.Core;
using Murmur.Windows.Services;
using Murmur.Windows.Views;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Murmur.Windows.IntegrationTests;

internal static class Program
{
    private static readonly List<object> Results = [];
    private static readonly List<Process> Processes = [];
    private static string output = "";
    private static int failures;

    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length != 2) throw new ArgumentException("Usage: <fixture directory> <output directory>");
        output = Path.GetFullPath(args[1]); Directory.CreateDirectory(output);
        var dispatcher = Dispatcher.CurrentDispatcher;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
        _ = RunAndExitAsync(Path.GetFullPath(args[0]), dispatcher);
        Dispatcher.Run();
    }
    private static async Task RunAndExitAsync(string fixtures, Dispatcher dispatcher)
    {
        try { await RunAsync(fixtures); }
        catch (Exception e) { Record("test harness", false, e.ToString()); }
        finally
        {
            foreach (var p in Processes) { try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } p.Dispose(); }
            File.WriteAllText(Path.Combine(output, "capture-paste-results.json"), JsonSerializer.Serialize(new
            {
                platform = RuntimeInformation.OSDescription,
                captureSource = "VB-CABLE virtual microphone; prerecorded JFK speech, no physical microphone",
                results = Results, failures
            }, new JsonSerializerOptions { WriteIndented = true }));
            Environment.ExitCode = failures == 0 ? 0 : 1;
            dispatcher.InvokeShutdown();
        }
    }
    private static async Task RunAsync(string fixtures)
    {
        Assert(Marshal.SizeOf<NativeMethods.Input>() == 40, "SendInput structure has the wrong x64 size.");
        string recognized = "";
        await Check("WASAPI capture → 16 kHz conversion → native transcription", async () =>
        {
            var microphones = AudioRecorder.Devices();
            Console.WriteLine("Capture devices: " + JsonSerializer.Serialize(microphones));
            var microphone = microphones.Single(m => m.Name.Contains("CABLE Output", StringComparison.OrdinalIgnoreCase));
            using var enumerator = new MMDeviceEnumerator();
            using var playback = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
                .Single(d => d.FriendlyName.Contains("CABLE Input", StringComparison.OrdinalIgnoreCase));
            using var recorder = new AudioRecorder();
            recorder.Start(microphone.Id);
            await Task.Delay(200);
            using var reader = new WaveFileReader(Path.Combine(fixtures, "jfk.wav"));
            using var player = new WasapiOut(playback, AudioClientShareMode.Shared, true, 50);
            var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            player.PlaybackStopped += (_, e) => { if (e.Exception is null) ended.TrySetResult(); else ended.TrySetException(e.Exception); };
            player.Init(reader); player.Play();
            await ended.Task.WaitAsync(TimeSpan.FromSeconds(30));
            await Task.Delay(300);
            var samples = await recorder.StopAsync();
            Assert(samples.Length > 16000 * 8, $"Too little captured audio: {samples.Length} samples.");
            Assert(samples.Any(s => Math.Abs(s) > 0.01), "Captured audio was silent.");
            using (var writer = new WaveFileWriter(Path.Combine(output, "virtual-microphone-capture.wav"), WaveFormat.CreateIeeeFloatWaveFormat(16000, 1))) writer.WriteSamples(samples, 0, samples.Length);
            using var http = new HttpClient();
            using var engine = new SpeechEngine(new ModelDownloader(http, fixtures));
            using var token = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            recognized = await engine.TranscribeAsync(samples, new() { ModelId = "tiny", Language = "en" }, token.Token);
            Assert(recognized.Contains("country", StringComparison.OrdinalIgnoreCase), "Capture did not transcribe the expected speech: " + recognized);
            File.WriteAllText(Path.Combine(output, "captured-transcript.txt"), recognized);

            for (var i = 0; i < 3; i++)
            {
                recorder.Start(microphone.Id); await Task.Delay(150); await recorder.StopAsync();
            }
            Record("three successive microphone start/stop cycles", true);
            recorder.Start(microphone.Id); var shortTake = await recorder.StopAsync();
            Assert(CapturePolicy.Evaluate(shortTake, TimeSpan.FromMilliseconds(20)) == CaptureOutcome.AccidentalTap, "Quick taps should cancel without an error.");
            Record("immediate microphone stop after shortcut release", true);
        });

        var notepad = Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true })!;
        Processes.Add(notepad);
        var noteWindow = await WaitWindow(() => { notepad.Refresh(); return notepad.MainWindowHandle; });
        var noteRoot = AutomationElement.FromHandle(noteWindow);
        var noteEditor = await FindEditor(noteRoot);

        await Check("Unicode paste into Notepad", async () =>
        {
            await Focus(noteWindow, noteEditor); await SelectAll();
            const string text = "Murmur — São Paulo, 日本語, café.\r\nSecond line.";
            var target = TextDelivery.CaptureTarget();
            var message = await TextDelivery.DeliverAsync(text, target, default);
            await WaitForText(noteEditor, text);
            Assert(Clipboard.GetText() == text, "Clipboard text was not preserved.");
            Console.WriteLine(message);
            SaveDesktop("notepad-unicode.png");
        });
        await Check("Captured speech pastes into Notepad", async () =>
        {
            Assert(recognized.Length > 0, "No captured speech is available.");
            await Focus(noteWindow, noteEditor); await SelectAll();
            var target = TextDelivery.CaptureTarget();
            var message = await TextDelivery.DeliverAsync(recognized, target, default);
            Console.WriteLine($"Captured-speech delivery: {message}; before={target}; after={TextDelivery.CaptureTarget()}");
            await WaitForText(noteEditor, recognized);
            SaveDesktop("notepad-captured-speech.png");
        });
        await Check("Recording overlay does not steal destination focus", async () =>
        {
            await Focus(noteWindow, noteEditor);
            var before = TextDelivery.CaptureTarget();
            var overlay = new RecordingOverlay();
            try
            {
                overlay.SetMessage("Test recording", true, false); overlay.Reveal(); await Task.Delay(300);
                Assert(TextDelivery.CaptureTarget() == before, "The overlay stole focus.");
            }
            finally { overlay.Close(); }
        });

        var chromePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google", "Chrome", "Application", "chrome.exe");
        var start = new ProcessStartInfo(chromePath) { UseShellExecute = false };
        start.ArgumentList.Add("--user-data-dir=" + Path.Combine(output, "chrome-profile"));
        start.ArgumentList.Add("--no-first-run"); start.ArgumentList.Add("--force-renderer-accessibility");
        start.ArgumentList.Add("--app=" + new Uri(Path.Combine(AppContext.BaseDirectory, "editor.html")).AbsoluteUri);
        var chrome = Process.Start(start)!; Processes.Add(chrome);
        var browserWindow = await WaitWindow(() => { chrome.Refresh(); return chrome.MainWindowHandle; });
        var browserRoot = AutomationElement.FromHandle(browserWindow);
        var first = await FindEditor(browserRoot, "First dictation field");
        var second = await FindEditor(browserRoot, "Second dictation field");

        await Check("Unicode paste into Chrome textarea", async () =>
        {
            await Focus(browserWindow, first);
            const string text = "Murmur browser test — São Paulo.\nA second line.";
            await TextDelivery.DeliverAsync(text, TextDelivery.CaptureTarget(), default);
            await WaitForText(first, text);
        });
        await Check("Changing browser fields prevents paste", async () =>
        {
            await Focus(browserWindow, first); var target = TextDelivery.CaptureTarget();
            await Focus(browserWindow, second);
            var message = await TextDelivery.DeliverAsync("Keep this on the clipboard.", target, default);
            await Task.Delay(200);
            Assert(ReadText(second).Length == 0, "Text was pasted into the wrong browser field.");
            Assert(message.StartsWith("Copied."), "Changing fields did not select the copy fallback.");
        });
        await Check("Switching apps prevents paste", async () =>
        {
            await Focus(noteWindow, noteEditor); var target = TextDelivery.CaptureTarget();
            await Focus(browserWindow, second);
            await TextDelivery.DeliverAsync("Wrong-window guard", target, default); await Task.Delay(200);
            Assert(ReadText(second).Length == 0, "Text was pasted into a different app.");
            Assert(Clipboard.GetText() == "Wrong-window guard", "The fallback did not copy the result.");
        });
        await Check("Held Ctrl prevents accidental shortcut input", async () =>
        {
            await Focus(browserWindow, second); var target = TextDelivery.CaptureTarget();
            Native.Key(0x11, false);
            try
            {
                await TextDelivery.DeliverAsync("Held modifier guard", target, default);
                Assert(ReadText(second).Length == 0, "Pasted while a modifier was held.");
            }
            finally { Native.Key(0x11, true); }
        });
        await Check("Canceled delivery leaves the target and clipboard unchanged", async () =>
        {
            var clipboard = Clipboard.GetText();
            using var cancel = new CancellationTokenSource(); cancel.Cancel();
            try { await TextDelivery.DeliverAsync("Canceled words", TextDelivery.CaptureTarget(), cancel.Token); throw new Exception("Cancellation was ignored."); }
            catch (OperationCanceledException) { }
            Assert(ReadText(second).Length == 0 && Clipboard.GetText() == clipboard, "Cancellation modified user content.");
        });
        await Check("Sequential pastes stay in the intended browser field", async () =>
        {
            await Focus(browserWindow, second);
            for (var i = 0; i < 3; i++)
            {
                await TextDelivery.DeliverAsync($"Take {i}. ", TextDelivery.CaptureTarget(), default);
                await Task.Delay(150);
            }
            await WaitForText(second, "Take 0. Take 1. Take 2. ");
            SaveDesktop("chrome-paste.png");
        });
    }

    private static async Task Check(string name, Func<Task> action)
    {
        try { await action(); Record(name, true); }
        catch (Exception e) { SaveDesktop($"failure-{failures + 1}.png"); Record(name, false, e.ToString()); }
    }
    private static void Record(string name, bool pass, string? error = null)
    {
        if (!pass) failures++;
        Results.Add(new { name, pass, error }); Console.WriteLine($"{(pass ? "PASS" : "FAIL")}: {name}" + (error is null ? "" : "\n" + error));
    }
    private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static async Task<nint> WaitWindow(Func<nint> get)
    {
        for (var i = 0; i < 80; i++) { var value = get(); if (value != 0) return value; await Task.Delay(250); }
        throw new TimeoutException("Application window did not appear.");
    }
    private static async Task<AutomationElement> FindEditor(AutomationElement root, string? name = null)
    {
        var type = new OrCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit), new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document));
        System.Windows.Automation.Condition condition = name is null ? type : new AndCondition(type, new PropertyCondition(AutomationElement.NameProperty, name));
        for (var i = 0; i < 40; i++) { var item = root.FindFirst(TreeScope.Descendants, condition); if (item is not null) return item; await Task.Delay(250); }
        throw new InvalidOperationException("No accessible editor found: " + name);
    }
    private static async Task Focus(nint window, AutomationElement element)
    {
        if (NativeMethods.GetForegroundWindow() != window)
        {
            Native.ShowWindow(window, 9);
            Native.Key(0x12, false); await Task.Delay(50); Native.Key(0x12, true); await Task.Delay(50);
            Native.SetForegroundWindow(window);
            await Task.Delay(200);
        }
        if (NativeMethods.GetForegroundWindow() != window)
        {
            // Test harness only: the production paste service never changes focus.
            var current = Native.GetCurrentThreadId();
            var foreground = NativeMethods.GetWindowThreadProcessId(NativeMethods.GetForegroundWindow(), out _);
            var attached = foreground != current && Native.AttachThreadInput(current, foreground, true);
            try { Native.SetForegroundWindow(window); }
            finally { if (attached) Native.AttachThreadInput(current, foreground, false); }
        }
        element.SetFocus(); await Task.Delay(250);
        Assert(NativeMethods.GetForegroundWindow() == window, "Could not focus the test destination.");
    }
    private static void SaveDesktop(string filename)
    {
        try
        {
            var bounds = System.Windows.Forms.SystemInformation.VirtualScreen;
            using var bitmap = new System.Drawing.Bitmap(bounds.Width, bounds.Height);
            using var graphics = System.Drawing.Graphics.FromImage(bitmap);
            graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size);
            bitmap.Save(Path.Combine(output, filename), System.Drawing.Imaging.ImageFormat.Png);
        }
        catch (Exception e) { Console.WriteLine("Screenshot unavailable: " + e.Message); }
    }
    private static async Task SelectAll()
    {
        Native.Key(0x11, false); Native.Key(0x41, false); Native.Key(0x41, true); Native.Key(0x11, true);
        // SendInput queues messages; let the destination handle them before
        // capturing the target and testing a separate application operation.
        await Task.Delay(150);
    }
    private static string ReadText(AutomationElement element)
    {
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value)) return ((ValuePattern)value).Current.Value;
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var text)) return ((TextPattern)text).DocumentRange.GetText(-1);
        throw new InvalidOperationException("Editor does not expose readable text.");
    }
    private static async Task WaitForText(AutomationElement element, string expected)
    {
        string actual = "";
        for (var i = 0; i < 30; i++)
        {
            actual = ReadText(element);
            if (actual.Replace("\r\n", "\n").TrimEnd('\r', '\n') == expected.Replace("\r\n", "\n").TrimEnd('\r', '\n')) return;
            await Task.Delay(100);
        }
        throw new InvalidOperationException($"Pasted text mismatch. Expected: {JsonSerializer.Serialize(expected)}; actual: {JsonSerializer.Serialize(actual)}");
    }
    private static class Native
    {
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint window);
        [DllImport("user32.dll")] internal static extern bool ShowWindow(nint window, int command);
        [DllImport("kernel32.dll")] internal static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] internal static extern bool AttachThreadInput(uint from, uint to, bool attach);
        internal static void Key(ushort key, bool up)
        {
            var inputs = new[] { new NativeMethods.Input { Type = 1, Union = new() { Keyboard = new() { Key = key, Flags = up ? 2u : 0u } } } };
            Assert(NativeMethods.SendInput(1, inputs, Marshal.SizeOf<NativeMethods.Input>()) == 1, "Unable to send test input.");
        }
    }
}
