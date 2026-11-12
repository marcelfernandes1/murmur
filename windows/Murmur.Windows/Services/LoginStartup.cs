using Microsoft.Win32;

namespace Murmur.Windows.Services;

internal static class LoginStartup
{
    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("Murmur", $"\"{Environment.ProcessPath}\" --background");
        else key.DeleteValue("Murmur", throwOnMissingValue: false);
    }
}
