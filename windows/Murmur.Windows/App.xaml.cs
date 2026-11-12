using System.Drawing;
using Murmur.Windows.Services;
using Murmur.Windows.Views;
using Forms = System.Windows.Forms;

namespace Murmur.Windows;

public partial class App : Application
{
    private Mutex? mutex;
    private EventWaitHandle? activateEvent;
    private RegisteredWaitHandle? activationWait;
    private Forms.NotifyIcon? tray;
    private DictationController? controller;
    private MainWindow? window;
    private bool exiting;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        mutex = new(true, @"Local\Murmur.Windows", out var first);
        if (!first)
        {
            try { using var signal = EventWaitHandle.OpenExisting(@"Local\Murmur.Windows.Activate"); signal.Set(); }
            catch (WaitHandleCannotBeOpenedException) { }
            Shutdown(); return;
        }
        try
        {
            controller = new(Dispatcher);
            window = new(controller);
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("Open Murmur", null, (_, _) => ShowMain());
            menu.Items.Add("Cancel dictation", null, (_, _) => controller.Cancel());
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("Quit Murmur", null, async (_, _) => await ExitAsync());
            using var iconStream = GetResourceStream(new Uri("pack://application:,,,/Assets/murmur.ico"))!.Stream;
            tray = new() { Icon = new Icon(iconStream), Visible = true, Text = "Murmur · Local dictation", ContextMenuStrip = menu };
            tray.DoubleClick += (_, _) => ShowMain();
            activateEvent = new(false, EventResetMode.AutoReset, @"Local\Murmur.Windows.Activate");
            activationWait = ThreadPool.RegisterWaitForSingleObject(activateEvent, (_, _) => Dispatcher.BeginInvoke(ShowMain), null, -1, false);
            controller.Changed += () => tray.Text = ("Murmur · " + controller.Status)[..Math.Min(63, 9 + controller.Status.Length)];
            if (!e.Args.Contains("--background") || !controller.Models.IsDownloaded(ModelCatalog.Find(controller.Settings.ModelId))) ShowMain();
            controller.Initialize();
        }
        catch (Exception)
        {
            MessageBox.Show("Murmur could not start. Make sure its folder is writable and all files were extracted, then try again.", "Murmur", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
    private void ShowMain() { window?.Show(); if (window is not null) { window.WindowState = WindowState.Normal; window.Activate(); } }
    private async Task ExitAsync()
    {
        if (exiting) return;
        exiting = true;
        tray!.Visible = false;
        if (controller is not null) await controller.ShutdownAsync();
        window?.AllowClose();
        Shutdown();
    }
    protected override void OnExit(ExitEventArgs e)
    {
        tray?.Dispose(); activationWait?.Unregister(null); activateEvent?.Dispose(); mutex?.Dispose();
        base.OnExit(e);
    }
}
