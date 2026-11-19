using System.Drawing;
using Murmur.Windows.Services;
using Murmur.Windows.Views;
using System.Windows.Threading;
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
        // An unexpected error must not silently close a tray app the user relies on.
        // Log it (never transcript text), reset any half-started dictation, keep running.
        DispatcherUnhandledException += (_, args) =>
        {
            ErrorReporter.Record(args.Exception, handled: true, "dispatcher");
            args.Handled = true;
            try { controller?.Cancel(); } catch (Exception inner) { CrashLog.Write(inner); }
        };
        TaskScheduler.UnobservedTaskException += (_, args) => { ErrorReporter.Record(args.Exception, handled: true, "unobserved_task"); args.SetObserved(); };
        // The process is ending: save the report; the user is asked on the next start.
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception error) ErrorReporter.Record(error, handled: false, "unhandled");
        };
        ErrorReporter.Recorded += () => Dispatcher.BeginInvoke(OfferReport);
        try
        {
            controller = new(Dispatcher);
            window = new(controller);
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("Open Murmur", null, (_, _) => ShowMain());
            menu.Items.Add("Cancel dictation", null, (_, _) => controller.Cancel());
            var report = menu.Items.Add("Send error report…", null, async (_, _) => await ErrorReporter.PromptAsync(afterCrash: false));
            menu.Opening += (_, _) => report.Visible = ErrorReporter.HasPending;
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("Quit Murmur", null, async (_, _) => await ExitAsync());
            using var iconStream = GetResourceStream(new Uri("pack://application:,,,/Assets/murmur.ico"))!.Stream;
            tray = new() { Icon = new Icon(iconStream), Visible = true, Text = "Murmur · Local dictation", ContextMenuStrip = menu };
            tray.DoubleClick += (_, _) => ShowMain();
            tray.BalloonTipClicked += async (_, _) => await ErrorReporter.PromptAsync(afterCrash: false);
            activateEvent = new(false, EventResetMode.AutoReset, @"Local\Murmur.Windows.Activate");
            activationWait = ThreadPool.RegisterWaitForSingleObject(activateEvent, (_, _) => Dispatcher.BeginInvoke(ShowMain), null, -1, false);
            controller.Changed += () => tray.Text = ("Murmur · " + controller.Status)[..Math.Min(63, 9 + controller.Status.Length)];
            if (!e.Args.Contains("--background") || !controller.Models.IsDownloaded(ModelCatalog.Find(controller.Settings.ModelId))) ShowMain();
            controller.Initialize();
            // Reports left from a crash or an unanswered problem: ask once the app is idle.
            if (ErrorReporter.HasPending)
                Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, async () => await ErrorReporter.PromptAsync(afterCrash: true));
        }
        catch (Exception error)
        {
            ErrorReporter.Record(error, handled: false, "startup");
            MessageBox.Show("Murmur could not start. Make sure its folder is writable and all files were extracted, then try again.", "Murmur", MessageBoxButton.OK, MessageBoxImage.Error);
            _ = ReportStartupFailureAsync();
        }
    }
    private async Task ReportStartupFailureAsync()
    {
        try { await ErrorReporter.PromptAsync(afterCrash: false); }
        finally { Shutdown(1); }
    }
    private DateTimeOffset lastOffer = DateTimeOffset.MinValue;
    /// A non-blocking nudge: dictation keeps working, the prompt opens only on click.
    private void OfferReport()
    {
        if (tray is null || exiting || DateTimeOffset.Now - lastOffer < TimeSpan.FromMinutes(10)) return;
        lastOffer = DateTimeOffset.Now;
        tray.ShowBalloonTip(10000, "Murmur hit a problem", "Click here to send an error report.", Forms.ToolTipIcon.Warning);
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
