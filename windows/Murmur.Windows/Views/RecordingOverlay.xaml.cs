using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Murmur.Windows.Services;
using Forms = System.Windows.Forms;

namespace Murmur.Windows.Views;

public partial class RecordingOverlay : Window
{
    private readonly List<Rectangle> bars = [];
    private float smoothed;
    internal event Action? Done;
    internal event Action? Cancel;
    public RecordingOverlay()
    {
        InitializeComponent();
        for (var i = 0; i < 28; i++)
        {
            var bar = new Rectangle { Width = 4, Height = 3, RadiusX = 2, RadiusY = 2, Fill = new SolidColorBrush(Color.FromRgb(90, 176, 255)), Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
            bars.Add(bar); Bars.Children.Add(bar);
        }
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            NativeMethods.SetWindowLongPtr(handle, -20, NativeMethods.GetWindowLongPtr(handle, -20) | 0x08000000 | 0x80);
            HwndSource.FromHwnd(handle)?.AddHook((nint hwnd, int msg, nint wp, nint lp, ref bool handled) =>
            {
                if (msg == 0x21) { handled = true; return 3; } // MA_NOACTIVATE
                return 0;
            });
        };
    }
    internal void Reveal()
    {
        var screen = Forms.Screen.FromHandle(NativeMethods.GetForegroundWindow());
        var scale = VisualTreeHelper.GetDpi(this);
        Left = screen.WorkingArea.Left / scale.DpiScaleX + (screen.WorkingArea.Width / scale.DpiScaleX - Width) / 2;
        Top = (screen.WorkingArea.Bottom / scale.DpiScaleY) - 180;
        if (!IsVisible) Show();
    }
    internal void SetMessage(string text, bool capturing, bool locked)
    {
        MessageText.Text = text;
        Actions.Visibility = locked ? Visibility.Visible : Visibility.Collapsed;
        if (!capturing) { foreach (var bar in bars) bar.Height = 3; ElapsedText.Text = ""; }
    }
    internal void UpdateLevel(float level, TimeSpan elapsed, bool locked)
    {
        smoothed += (level - smoothed) * 0.35f;
        for (var i = 0; i < bars.Count; i++) bars[i].Height = 3 + 23 * smoothed * (0.4 + 0.6 * Math.Abs(Math.Sin(i * 1.7 + (SystemParameters.ClientAreaAnimation ? elapsed.TotalSeconds * 4 : 0))));
        ElapsedText.Text = (locked ? "HANDS-FREE · " : "") + elapsed.ToString(@"m\:ss");
    }
    private void Done_Click(object sender, RoutedEventArgs e) => Done?.Invoke();
    private void Cancel_Click(object sender, RoutedEventArgs e) => Cancel?.Invoke();
}
