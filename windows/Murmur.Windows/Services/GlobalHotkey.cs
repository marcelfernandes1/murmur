using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace Murmur.Windows.Services;

/// The low-level keyboard hook runs on its own thread with its own message loop.
/// Windows silently removes a low-level hook whose thread is slow to answer
/// (LowLevelHooksTimeout). On the UI thread, any pause — UI Automation calls,
/// clipboard waits, disk writes, layout — could kill the shortcut until restart
/// and drop a key release, leaving a recording stuck. This thread only queues
/// work to the UI dispatcher, so it always answers immediately.
internal sealed class GlobalHotkey : IDisposable
{
    private readonly NativeMethods.KeyboardProc callback;
    private readonly Dispatcher dispatcher;
    private readonly Thread thread;
    private readonly HashSet<int> suppressed = []; // Hook thread only.
    private readonly bool acceptInjected;
    private nint hook;
    private uint threadId;
    private volatile int triggerKey = 0xA3;
    private volatile bool canLock;
    private volatile bool canCancel;
    public int TriggerKey { get => triggerKey; set => triggerKey = value; }
    public bool CanLock { get => canLock; set => canLock = value; }
    public bool CanCancel { get => canCancel; set => canCancel = value; }
    public event Action? Pressed;
    public event Action? Released;
    public event Action? LockRequested;
    public event Action? CancelRequested;

    /// acceptInjected exists only so Windows CI can drive the real hook with SendInput.
    public GlobalHotkey(Dispatcher dispatcher, bool acceptInjected = false)
    {
        this.dispatcher = dispatcher;
        this.acceptInjected = acceptInjected;
        callback = OnKey;
        using var ready = new ManualResetEventSlim();
        Exception? failure = null;
        thread = new Thread(() =>
        {
            threadId = NativeMethods.GetCurrentThreadId();
            // Force the thread's message queue to exist before anyone posts WM_QUIT.
            NativeMethods.PeekMessage(out _, 0, 0, 0, 0);
            hook = NativeMethods.SetWindowsHookEx(13, callback, NativeMethods.GetModuleHandle(null), 0);
            if (hook == 0) failure = new Win32Exception(Marshal.GetLastWin32Error(), "Could not register the dictation shortcut.");
            ready.Set();
            if (hook == 0) return;
            // Low-level hook callbacks are delivered while this thread waits here.
            while (NativeMethods.GetMessage(out _, 0, 0, 0) > 0) { }
            NativeMethods.UnhookWindowsHookEx(hook);
            hook = 0;
        })
        { IsBackground = true, Name = "Murmur keyboard hook", Priority = ThreadPriority.AboveNormal };
        thread.Start();
        ready.Wait();
        if (failure is not null) throw failure;
    }

    private nint OnKey(int code, nint message, nint data)
    {
        if (code < 0) return NativeMethods.CallNextHookEx(hook, code, message, data);
        var key = Marshal.PtrToStructure<NativeMethods.KeyboardData>(data);
        if ((key.Flags & 0x10) != 0 && !acceptInjected) return NativeMethods.CallNextHookEx(hook, code, message, data); // Ignore injected events.
        var down = message is 0x100 or 0x104;
        var up = message is 0x101 or 0x105;
        var vk = (int)key.Key;
        // Remember consumed keys so their up event is also suppressed after state changes.
        if (up && suppressed.Remove(vk))
        {
            if (vk == triggerKey) dispatcher.BeginInvoke(() => Released?.Invoke());
            return 1;
        }
        if (!down) return NativeMethods.CallNextHookEx(hook, code, message, data);
        Action? action = vk == triggerKey ? () => Pressed?.Invoke()
            : vk == 0x20 && canLock ? () => LockRequested?.Invoke()
            : vk == 0x1B && canCancel ? () => CancelRequested?.Invoke() : null;
        if (action is null) return NativeMethods.CallNextHookEx(hook, code, message, data);
        if (suppressed.Add(vk)) dispatcher.BeginInvoke(action);
        return 1;
    }

    public void Dispose()
    {
        if (threadId != 0 && thread.IsAlive) NativeMethods.PostThreadMessage(threadId, 0x12, 0, 0); // WM_QUIT
        thread.Join(TimeSpan.FromSeconds(2));
    }
}
