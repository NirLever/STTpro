using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace STTpro.App.Views;

public partial class RecordingIndicator : Window
{
    private readonly DispatcherTimer _timer;
    private DateTime _recordingStartTime;
    private IntPtr _targetWindowHwnd;

    // --- Live waveform state ---
    private System.Windows.Shapes.Rectangle[]? _bars;
    private double _phase;
    private DateTime _lastAudioUtc = DateTime.UtcNow;
    private DispatcherTimer? _waveTimer;
    private float _currentLevel;
    private DateTime _lastSignalUtc = DateTime.UtcNow;
    private bool _recordingActive;

    private const double BarMin = 3;
    private const double BarMax = 21;

    // Below this the input is treated as room noise, so quiet reads as visibly flat.
    private const double NoiseGate = 0.012;
    // Speech rarely peaks near 1.0, so scale it up to use the full bar height.
    private const double Gain = 2.6;

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

        _bars = new[] { Bar0, Bar1, Bar2, Bar3, Bar4, Bar5, Bar6, Bar7, Bar8, Bar9 };

        // Repaint the waveform on its own cadence so it stays smooth regardless of how
        // often the audio callback fires.
        _waveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(30) };
        _waveTimer.Tick += WaveTimer_Tick;
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

    /// <summary>
    /// Feed the latest microphone level (0..1) from the audio capture callback.
    /// Jumps straight to a new peak and falls away quickly, so the bars track speech
    /// closely instead of lagging behind it.
    /// </summary>
    public void SetLevel(float level)
    {
        _lastAudioUtc = DateTime.UtcNow;

        if (level > _currentLevel)
            _currentLevel = level;                             // attack: instant
        else
            _currentLevel += (level - _currentLevel) * 0.32f;  // release: quick, so silence is obvious

        if (level > NoiseGate)
            _lastSignalUtc = DateTime.UtcNow;
    }

    /// <summary>
    /// Maps a raw mic level to 0..1 display energy: gate out room noise so quiet is truly
    /// flat, then boost so ordinary speech uses most of the bar height.
    /// </summary>
    private static double Shape(double level)
    {
        if (level <= NoiseGate) return 0;
        double v = Math.Min(1.0, (level - NoiseGate) * Gain);
        return Math.Pow(v, 0.55); // lift quiet speech without flattening loud speech
    }

    private void WaveTimer_Tick(object? sender, EventArgs e)
    {
        if (_bars == null) return;

        _phase += 0.42;
        double energy = Shape(_currentLevel);

        for (int i = 0; i < _bars.Length; i++)
        {
            // Every bar responds to the CURRENT level, so the waveform reacts the instant you
            // speak (the old version scrolled a history, which cost ~0.5s before it filled in).
            // A centre-weighted envelope plus a travelling ripple keeps it looking like a wave
            // rather than a solid block.
            double envelope = 0.45 + 0.55 * Math.Sin(Math.PI * (i + 0.5) / _bars.Length);
            double ripple = 0.78 + 0.22 * Math.Sin(_phase + i * 0.7);
            double target = BarMin + (BarMax - BarMin) * energy * envelope * ripple;

            double h = _bars[i].Height;
            // Snap up, ease down: talking registers immediately, silence settles visibly flat.
            double k = target > h ? 0.85 : 0.30;
            _bars[i].Height = h + (target - h) * k;
        }

        // Safety decay if audio callbacks stop arriving entirely.
        if ((DateTime.UtcNow - _lastAudioUtc).TotalMilliseconds > 250)
            _currentLevel *= 0.70f;

        // Surface a clear hint when the mic is delivering nothing at all.
        bool silent = _recordingActive && (DateTime.UtcNow - _lastSignalUtc).TotalSeconds > 2.5;
        var wanted = silent ? Visibility.Visible : Visibility.Collapsed;
        if (NoSignalWarning.Visibility != wanted)
            NoSignalWarning.Visibility = wanted;
    }

    private void ResetWave()
    {
        _currentLevel = 0;
        _phase = 0;
        _lastAudioUtc = DateTime.UtcNow;
        _lastSignalUtc = DateTime.UtcNow;
        if (_bars != null)
            foreach (var b in _bars) b.Height = BarMin;
        NoSignalWarning.Visibility = Visibility.Collapsed;
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
        _recordingActive = true;
        ResetWave();
        WavePanel.Visibility = Visibility.Visible;
        _waveTimer?.Start();


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

            _waveTimer?.Stop();

            _recordingActive = false;

            WavePanel.Visibility = Visibility.Collapsed;

            NoSignalWarning.Visibility = Visibility.Collapsed;
        }
    }

    public new void Hide()
    {
        _timer.Stop();
        _waveTimer?.Stop();
        _recordingActive = false;
        NoSignalWarning.Visibility = Visibility.Collapsed;
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
