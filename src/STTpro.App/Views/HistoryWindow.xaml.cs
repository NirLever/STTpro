using System.Windows;
using System.Windows.Input;
using STTpro.Core.History;
using STTpro.Core.Output;
using STTpro.Core.Settings;

namespace STTpro.App.Views;

public partial class HistoryWindow : Window
{
    private readonly ITranscriptRepository _history;
    private readonly ITextOutputService _output;
    private readonly ISettingsService _settings;

    public HistoryWindow(ITranscriptRepository history, ITextOutputService output, ISettingsService settings)
    {
        _history = history;
        _output = output;
        _settings = settings;
        InitializeComponent();
        Loaded += async (_, _) => await LoadHistoryAsync();
    }

    private async Task LoadHistoryAsync()
    {
        var records = await _history.GetRecentAsync(200);
        TranscriptList.ItemsSource = records;
    }

    private async void Search_Click(object sender, RoutedEventArgs e)
    {
        await SearchAsync();
    }

    private async void SearchBox_KeyUp(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
            await SearchAsync();
    }

    private async Task SearchAsync()
    {
        var query = SearchBox.Text.Trim();
        if (string.IsNullOrEmpty(query))
        {
            await LoadHistoryAsync();
            return;
        }

        var results = await _history.SearchAsync(query);
        TranscriptList.ItemsSource = results;
    }

    private void TranscriptList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        var hasSelection = TranscriptList.SelectedItem != null;
        CopyBtn.IsEnabled = hasSelection;
        DeleteBtn.IsEnabled = hasSelection;
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (TranscriptList.SelectedItem is TranscriptRecord record)
        {
            Clipboard.SetText(record.Text);
        }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (TranscriptList.SelectedItem is TranscriptRecord record)
        {
            await _history.DeleteAsync(record.Id);
            await LoadHistoryAsync();
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        SearchBox.Clear();
        await LoadHistoryAsync();
    }
}
