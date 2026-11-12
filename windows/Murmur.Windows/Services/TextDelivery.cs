using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace Murmur.Windows.Services;

internal sealed record DeliveryTarget(nint Window, nint Focus, uint ProcessId, string? ElementId = null);
internal static class TextDelivery
{
    public static DeliveryTarget CaptureTarget()
    {
        var window = NativeMethods.GetForegroundWindow();
        var thread = NativeMethods.GetWindowThreadProcessId(window, out var processId);
        var info = new NativeMethods.GuiThreadInfo { Size = (uint)Marshal.SizeOf<NativeMethods.GuiThreadInfo>() };
        var focus = NativeMethods.GetGUIThreadInfo(thread, ref info) ? info.Focus : 0;
        string? elementId = null;
        try
        {
            // Browsers can share one native HWND across multiple editable fields.
            var element = AutomationElement.FocusedElement;
            if (element is not null) elementId = string.Join(":", element.GetRuntimeId());
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException) { }
        return new(window, focus, processId, elementId);
    }
    public static async Task CopyAsync(string text, CancellationToken token)
    {
        for (var attempt = 0; ; attempt++)
        {
            token.ThrowIfCancellationRequested();
            try { Clipboard.SetText(text); return; }
            catch (COMException) when (attempt < 5) { await Task.Delay(60, token); }
        }
    }
    public static async Task<string> DeliverAsync(string text, DeliveryTarget target, CancellationToken token)
    {
        await CopyAsync(text, token);
        // Do not release keys held by the user or refocus a window behind their back.
        for (var i = 0; i < 20 && ModifiersHeld(); i++) await Task.Delay(50, token);
        token.ThrowIfCancellationRequested();
        var now = CaptureTarget();
        if (target.Window == 0 || target.Focus == 0 || target.ProcessId == Environment.ProcessId ||
            now != target || ModifiersHeld()) return "Copied. Paste when you’re ready.";
        NativeMethods.Input Key(ushort key, bool up) => new()
        {
            Type = 1,
            Union = new() { Keyboard = new() { Key = key, Flags = up ? 2u : 0u } }
        };
        var inputs = new[] { Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true) };
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());
        if (sent > 0 && sent < inputs.Length)
        {
            var release = new[] { Key(0x56, true), Key(0x11, true) };
            NativeMethods.SendInput((uint)release.Length, release, Marshal.SizeOf<NativeMethods.Input>());
        }
        // SendInput cannot verify that another app accepted a paste. The copy remains.
        return sent == inputs.Length ? "Paste sent. Your text is also copied." : "Copied. Press Ctrl+V to paste into this app.";
    }
    private static bool ModifiersHeld() => new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(k => (NativeMethods.GetAsyncKeyState(k) & 0x8000) != 0);
}
