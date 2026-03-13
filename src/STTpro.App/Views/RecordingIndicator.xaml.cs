using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace STTpro.App.Views;

public partial class RecordingIndicator : Window
{
    private readonly DispatcherTimer _timer;
    private DateTime _recordingStartTime;
    private IntPtr _targetWindowHwnd;

    /// <summary>User clicked the stop button (finish recording and transcribe).</summary>
    public event EventHandler? StopRequested;
    /// <summary>User clicked the cancel button (discard recording).</summary>
    public event EventHandler? CancelRequested;

    public RecordingIndicator()
    {
        InitializeComponent();
        Visibility = Visibility.Collapsed;

        _timer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(200)
        };
        _timer.Tick += Timer_Tick;
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        PositionOnTargetMonitor();
    }

    private void Timer_Tick(object? sender, EventArgs e)
    {
        var elapsed = DateTime.UtcNow - _recordingStartTime;
        TimerText.Text = elapsed.TotalHours >= 1
            ? elapsed.ToString(@"h\:mm\:ss")
            : elapsed.ToString(@"m\:ss");
    }

    private void PositionOnTargetMonitor()
    {
        try
        {
            var screen = GetTargetScreen();
            var workArea = screen.WorkingArea;
            double dpi = GetDpiScale();

            // Bottom-center of the screen (more visible than bottom-right)
            double indicatorWidth = ActualWidth > 0 ? ActualWidth : 240;
            Left = (workArea.Left + workArea.Right) / (2 * dpi) - indicatorWidth / 2;
            Top = workArea.Bottom / dpi - Height - 24;
        }
        catch
        {
            var workArea = SystemParameters.WorkArea;
            double indicatorWidth = ActualWidth > 0 ? ActualWidth : 240;
            Left = (workArea.Left + workArea.Right) / 2 - indicatorWidth / 2;
            Top = workArea.Bottom - Height - 24;
        }
    }

    private System.Windows.Forms.Screen GetTargetScreen()
    {
        if (_targetWindowHwnd != IntPtr.Zero)
        {
            if (GetWindowRect(_targetWindowHwnd, out var rect))
            {
                var point = new System.Drawing.Point(
                    (rect.Left + rect.Right) / 2,
                    (rect.Top + rect.Bottom) / 2);
                return System.Windows.Forms.Screen.FromPoint(point);
            }
        }

        GetCursorPos(out var cursorPos);
        return System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(cursorPos.X, cursorPos.Y));
    }

    private double GetDpiScale()
    {
        var source = PresentationSource.FromVisual(this);
        return source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
    }

    public void ShowForWindow(IntPtr targetHwnd)
    {
        _targetWindowHwnd = targetHwnd;
        _recordingStartTime = DateTime.UtcNow;
        TimerText.Text = "0:00";

        // Show interactive buttons during recording
        StopBtn.Visibility = Visibility.Visible;
        CancelBtn.Visibility = Visibility.Visible;
        RecordingDot.Visibility = Visibility.Visible;

        Visibility = Visibility.Visible;
        base.Show();
        PositionOnTargetMonitor();
        _timer.Start();
    }

    public new void Show()
    {
        ShowForWindow(IntPtr.Zero);
    }

    public void SetPromptLabel(string text)
    {
        PromptLabel.Text = text;
        // When showing a status label (Transcribing.../Processing...), hide the interactive buttons
        if (text is "Transcribing..." or "Processing...")
        {
            StopBtn.Visibility = Visibility.Collapsed;
            CancelBtn.Visibility = Visibility.Collapsed;
            _timer.Stop();
        }
    }

    public new void Hide()
    {
        _timer.Stop();
        PromptLabel.Text = "";
        Visibility = Visibility.Collapsed;
    }

    private void StopBtn_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        StopRequested?.Invoke(this, EventArgs.Empty);
    }

    private void CancelBtn_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        CancelRequested?.Invoke(this, EventArgs.Empty);
    }

    // P/Invoke for window rect and cursor position
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct POINT
    {
        public int X, Y;
    }
}
