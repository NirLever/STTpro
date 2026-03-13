using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace STTpro.App.Views;

public partial class PromptToast : Window
{
    private readonly DispatcherTimer _hideTimer;

    public PromptToast()
    {
        InitializeComponent();
        Visibility = Visibility.Collapsed;
        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _hideTimer.Tick += (_, _) =>
        {
            _hideTimer.Stop();
            FadeOut();
        };
    }

    public void ShowToast(string message)
    {
        _hideTimer.Stop();
        ToastText.Text = message;
        Opacity = 1.0;
        Visibility = Visibility.Visible;
        base.Show();
        PositionBottomCenter();
        _hideTimer.Start();
    }

    private void FadeOut()
    {
        var anim = new DoubleAnimation(1.0, 0.0, TimeSpan.FromMilliseconds(300));
        anim.Completed += (_, _) => Visibility = Visibility.Collapsed;
        BeginAnimation(OpacityProperty, anim);
    }

    private void PositionBottomCenter()
    {
        try
        {
            UpdateLayout();
            var workArea = SystemParameters.WorkArea;
            double w = ActualWidth > 0 ? ActualWidth : 200;
            Left = (workArea.Left + workArea.Right) / 2 - w / 2;
            Top = workArea.Bottom - ActualHeight - 80; // above the recording indicator
        }
        catch { }
    }
}
