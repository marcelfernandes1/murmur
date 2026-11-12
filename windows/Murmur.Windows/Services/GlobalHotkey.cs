using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace Murmur.Windows.Services;

internal sealed class GlobalHotkey : IDisposable
{
    private readonly NativeMethods.KeyboardProc callback;
    private readonly Dispatcher dispatcher;
    private nint hook;
    private readonly HashSet<int> suppressed = [];
    public int TriggerKey { get; set; } = 0xA3;
    public bool CanLock { get; set; }
    public bool CanCancel { get; set; }
    public event Action? Pressed;
    public event Action? Released;
    public event Action? LockRequested;
    public event Action? CancelRequested;
    public GlobalHotkey(Dispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        callback = OnKey;
        hook = NativeMethods.SetWindowsHookEx(13, callback, NativeMethods.GetModuleHandle(null), 0);
        if (hook == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not register the dictation shortcut.");
    }

    private nint OnKey(int code, nint message, nint data)
    {
        if (code < 0) return NativeMethods.CallNextHookEx(hook, code, message, data);
        var key = Marshal.PtrToStructure<NativeMethods.KeyboardData>(data);
        if ((key.Flags & 0x10) != 0) return NativeMethods.CallNextHookEx(hook, code, message, data); // Ignore injected events.
        var down = message is 0x100 or 0x104;
        var up = message is 0x101 or 0x105;
        var vk = (int)key.Key;
        // Remember consumed keys so their up event is also suppressed after state changes.
        if (up && suppressed.Remove(vk))
        {
            if (vk == TriggerKey) dispatcher.BeginInvoke(() => Released?.Invoke());
            return 1;
        }
        if (!down) return NativeMethods.CallNextHookEx(hook, code, message, data);
        Action? action = vk == TriggerKey ? () => Pressed?.Invoke()
            : vk == 0x20 && CanLock ? () => LockRequested?.Invoke()
            : vk == 0x1B && CanCancel ? () => CancelRequested?.Invoke() : null;
        if (action is null) return NativeMethods.CallNextHookEx(hook, code, message, data);
        if (suppressed.Add(vk)) dispatcher.BeginInvoke(action);
        return 1;
    }
    public void Dispose() { if (hook != 0) NativeMethods.UnhookWindowsHookEx(hook); hook = 0; }
}
