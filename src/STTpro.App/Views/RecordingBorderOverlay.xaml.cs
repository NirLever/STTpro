using System.Windows;
using System.Windows.Threading;

namespace STTpro.App.Views;

public partial class RecordingBorderOverlay : Window
{
    private IntPtr _targetHwnd;
    private readonly DispatcherTimer _positionTimer;

    public RecordingBorderOverlay()
    {
        InitializeComponent();
        Visibility = Visibility.Collapsed;

        // Periodically re-track the target window position (in case it moves/resizes)
        _positionTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(250)
        };
        _positionTimer.Tick += (_, _) => UpdatePosition();
    }

    public void ShowForWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;

        _targetHwnd = hwnd;
        UpdatePosition();
        Visibility = Visibility.Visible;
        base.Show();
        _positionTimer.Start();
    }

    public new void Hide()
    {
        _positionTimer.Stop();
        Visibility = Visibility.Collapsed;
    }

    private void UpdatePosition()
    {
        if (_targetHwnd == IntPtr.Zero) return;

        if (!GetWindowRect(_targetHwnd, out var rect))
        {
            // Window may have been closed
            Hide();
            return;
        }

        double dpi = GetDpiScale();

        // Position overlay exactly on top of the target window
        Left = rect.Left / dpi - 3;
        Top = rect.Top / dpi - 3;
        Width = (rect.Right - rect.Left) / dpi + 6;
        Height = (rect.Bottom - rect.Top) / dpi + 6;
    }

    private double GetDpiScale()
    {
        var source = PresentationSource.FromVisual(this);
        return source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }
}
