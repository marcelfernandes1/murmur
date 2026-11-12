using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Murmur.Windows.Services;

internal sealed record Microphone(string? Id, string Name)
{
    public override string ToString() => Name;
}

internal sealed class AudioRecorder : IDisposable
{
    private WasapiCapture? capture;
    private MMDevice? device;
    private readonly object sync = new();
    private MemoryStream? audio;
    private TaskCompletionSource? stopped;
    private bool stopping;
    public event Action<Exception?>? Ended;
    public float Level { get; private set; }

    public static List<Microphone> Devices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<Microphone> { new(null, "Windows default microphone") };
        foreach (var item in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            using (item) result.Add(new(item.ID, item.FriendlyName));
        }
        return result;
    }

    public void Start(string? deviceId)
    {
        if (capture is not null) throw new InvalidOperationException("A recording is already in progress.");
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            device = deviceId is null ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia) : enumerator.GetDevice(deviceId);
            capture = new WasapiCapture(device) { WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(48000, 1) };
            audio = new MemoryStream();
            stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
            stopping = false;
            capture.DataAvailable += OnData;
            capture.RecordingStopped += (_, e) =>
            {
                if (e.Exception is null) stopped?.TrySetResult(); else stopped?.TrySetException(e.Exception);
                if (!stopping) Ended?.Invoke(e.Exception);
            };
            capture.StartRecording();
        }
        catch { DisposeCapture(); throw; }
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        double sum = 0;
        for (var i = 0; i + 3 < e.BytesRecorded; i += 4)
        {
            var value = BitConverter.ToSingle(e.Buffer, i);
            sum += value * value;
        }
        Level = (float)Math.Min(1, Math.Sqrt(sum / Math.Max(1, e.BytesRecorded / 4)) * 8);
        lock (sync) audio?.Write(e.Buffer, 0, e.BytesRecorded);
    }

    public async Task<float[]> StopAsync()
    {
        var current = capture;
        if (current is null) return [];
        try
        {
            stopping = true;
            current.StopRecording();
            await stopped!.Task.WaitAsync(TimeSpan.FromSeconds(5));
            byte[] bytes;
            lock (sync) bytes = audio!.ToArray();
            using var stream = new RawSourceWaveStream(new MemoryStream(bytes), current.WaveFormat);
            var provider = new WdlResamplingSampleProvider(stream.ToSampleProvider(), 16000);
            var result = new List<float>(bytes.Length / 12);
            var buffer = new float[16000];
            int count;
            while ((count = provider.Read(buffer, 0, buffer.Length)) > 0) result.AddRange(buffer.Take(count));
            return result.ToArray();
        }
        finally { DisposeCapture(); }
    }
    private void DisposeCapture()
    {
        stopping = true;
        capture?.Dispose(); capture = null;
        device?.Dispose(); device = null;
        lock (sync) { audio?.Dispose(); audio = null; }
        Level = 0;
    }
    public void Dispose() => DisposeCapture();
}
