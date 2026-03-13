using System.Windows;

namespace STTpro.App.Views;

public partial class ResetSettingsDialog : Window
{
    public bool Confirmed { get; private set; }
    public bool ResetPrompts => ResetPromptsCheck.IsChecked == true;

    public ResetSettingsDialog()
    {
        InitializeComponent();
    }

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = false;
        Close();
    }
}
