using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using STTpro.Core.Audio;
using STTpro.Core.History;
using STTpro.Core.Hotkeys;
using STTpro.Core.Security;
using STTpro.Core.Settings;

namespace STTpro.App.Views;

public partial class SettingsWindow : Window
{
    private readonly ISettingsService _settings;
    private readonly DpapiCredentialStore _credStore;
    private readonly IAudioCaptureService _audio;
    private readonly IGlobalHotkeyService? _hotkeyService;
    private readonly ITranscriptRepository? _history;
    private bool _loading = true;

    // Hotkey capture state
    private Button? _capturingButton;
    private string? _capturingTarget; // "hold", "toggle", "paste"
    private uint _capturedModifiers;
    private uint _capturedKeyCode;

    public SettingsWindow(ISettingsService settings, DpapiCredentialStore credStore, IAudioCaptureService audio,
        IGlobalHotkeyService? hotkeyService = null, ITranscriptRepository? history = null,
        Action? openHistoryWindow = null)
    {
        _settings = settings;
        _credStore = credStore;
        _audio = audio;
        _hotkeyService = hotkeyService;
        _history = history;
        InitializeComponent();
        LoadSettings();
        LoadUsageStats();
        LoadPrompts();
        _ = LoadHistoryAsync();
        _loading = false;

        // Wire up search box enter key
        HistorySearchBox.KeyUp += (_, e) => { if (e.Key == Key.Enter) _ = SearchHistoryAsync(); };
    }

    private void LoadSettings()
    {
        var s = _settings.Current;

        // --- Provider combos ---
        LoadProviderCombo(SttProviderCombo, ApiProviders.SttPresets, s.SttProvider.ProviderType);
        LoadProviderCombo(LlmProviderCombo, ApiProviders.LlmPresets, s.LlmProvider.ProviderType);

        // STT provider details
        UpdateSttProviderUI();
        // LLM provider details
        UpdateLlmProviderUI();

        // Microphone list
        var devices = _audio.GetInputDevices();
        MicrophoneCombo.Items.Clear();
        foreach (var dev in devices)
            MicrophoneCombo.Items.Add(new ComboBoxItem { Content = dev.Name, Tag = dev.Index });
        if (s.SelectedMicrophoneIndex >= 0 && s.SelectedMicrophoneIndex < devices.Count)
            MicrophoneCombo.SelectedIndex = s.SelectedMicrophoneIndex;
        else if (devices.Count > 0)
            MicrophoneCombo.SelectedIndex = 0;

        // Output mode
        SelectComboByTag(OutputModeCombo, s.OutputMode);

        // Language
        SelectComboByTag(LanguageCombo, s.LanguageHint ?? "");

        // Hotkeys display
        HoldToTalkBtn.Content = s.HoldToTalkHotkey.DisplayName;
        ToggleRecordingBtn.Content = s.ToggleRecordingHotkey.DisplayName;
        PasteLastBtn.Content = s.PasteLastTranscriptHotkey.DisplayName;

        // Options
        ShowIndicatorCheck.IsChecked = s.ShowRecordingIndicator;
        RestoreClipboardCheck.IsChecked = s.RestoreClipboard;
        AddTrailingPeriodCheck.IsChecked = s.AddTrailingPeriod;
        SkipShortRecordingsCheck.IsChecked = s.SkipShortRecordings;
        LaunchOnStartupCheck.IsChecked = s.LaunchOnStartup;

        // Silence sensitivity
        SilenceSlider.Value = s.SilenceThreshold;
        SilenceThresholdLabel.Text = s.SilenceThreshold.ToString("F2");

        // History retention
        SelectComboByTag(HistoryRetentionCombo, s.MaxHistoryItems.ToString());
    }

    // --- Model descriptions (shown as tooltips in dropdowns) ---

    private static readonly Dictionary<string, string> ModelDescriptions = new()
    {
        // STT models
        ["whisper-1"] = "OpenAI's original Whisper. Reliable and widely tested. ~$0.006/min.",
        ["gpt-4o-transcribe"] = "GPT-4o-based transcription. Higher accuracy, better context understanding. ~$0.006/min.",
        ["whisper-large-v3"] = "Whisper Large V3 on Groq. High quality, very fast. Free tier available.",
        ["whisper-large-v3-turbo"] = "Faster variant of Whisper V3. Best speed/accuracy balance. Free tier available.",
        ["distil-whisper-large-v3-en"] = "English-only optimized Whisper. Fastest for English audio. Free tier available.",

        // OpenAI LLM models
        ["gpt-4o-mini"] = "Fast and cheap. Great for simple cleanup and formatting. ~$0.15/$0.60 per 1M tokens.",
        ["gpt-4.1-nano"] = "Smallest GPT-4.1. Ultra-fast, lowest cost. Good for basic text cleanup. ~$0.10/$0.40 per 1M tokens.",
        ["gpt-4.1-mini"] = "Small GPT-4.1. Good balance of quality and cost. ~$0.40/$1.60 per 1M tokens.",
        ["gpt-4o"] = "Full GPT-4o. Higher quality for complex summarization. ~$2.50/$10 per 1M tokens.",
        ["gpt-4.1"] = "Latest GPT-4.1. Best quality from OpenAI for demanding tasks. ~$2/$8 per 1M tokens.",
        ["o4-mini"] = "Reasoning model. Best for complex analysis and structured extraction. ~$1.10/$4.40 per 1M tokens.",
        ["o3-mini"] = "Smaller reasoning model. Good for structured output and logic tasks. ~$1.10/$4.40 per 1M tokens.",

        // Groq LLM models
        ["llama-3.3-70b-versatile"] = "Large Llama 3.3. Versatile and capable. Free tier on Groq.",
        ["llama-3.1-8b-instant"] = "Small Llama 3.1. Ultra-fast responses. Free tier on Groq.",
        ["gemma2-9b-it"] = "Google's Gemma 2 9B. Good instruction following. Free tier on Groq.",
        ["mixtral-8x7b-32768"] = "Mixtral MoE. 32K context window, good quality. Free tier on Groq.",

        // Gemini models
        ["gemini-2.0-flash"] = "Google's fast multimodal model. Supports audio input for STT. Very low cost.",
        ["gemini-2.5-flash"] = "Latest fast Gemini with improved reasoning. Great quality/cost ratio.",
        ["gemini-2.5-pro"] = "Best Gemini model. Highest quality for complex tasks. More expensive.",

        // DeepSeek models
        ["deepseek-chat"] = "DeepSeek V3 chat model. Very capable, extremely low cost. ~$0.27/$1.10 per 1M tokens.",
        ["deepseek-reasoner"] = "DeepSeek R1 reasoning model. Chain-of-thought for complex tasks. ~$0.55/$2.19 per 1M tokens.",

        // OpenRouter models
        ["openai/gpt-4o-mini"] = "GPT-4o Mini via OpenRouter. Pay-per-use, no subscription needed.",
        ["anthropic/claude-3.5-sonnet"] = "Claude 3.5 Sonnet via OpenRouter. Excellent at following instructions.",
        ["google/gemini-2.0-flash-exp"] = "Gemini 2.0 Flash via OpenRouter. Fast and capable.",
        ["meta-llama/llama-3.3-70b-instruct"] = "Llama 3.3 70B via OpenRouter. Strong open-source model.",

        // Local models
        ["llama3.2"] = "Llama 3.2 locally via Ollama. Private, no API costs. Requires ~4-8GB RAM.",
        ["mistral"] = "Mistral 7B locally via Ollama. Fast and capable. Requires ~4GB RAM.",
        ["phi3"] = "Microsoft Phi-3 locally via Ollama. Small but smart. Requires ~2-4GB RAM.",
    };

    private static ComboBoxItem CreateModelItem(string model)
    {
        var item = new ComboBoxItem { Tag = model };
        if (ModelDescriptions.TryGetValue(model, out var desc))
        {
            var panel = new StackPanel { Margin = new Thickness(0, 2, 0, 2) };
            panel.Children.Add(new TextBlock
            {
                Text = model,
                FontWeight = FontWeights.SemiBold,
                FontSize = 12
            });
            var descBlock = new TextBlock
            {
                Text = desc,
                FontSize = 10,
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 280
            };
            descBlock.SetResourceReference(TextBlock.ForegroundProperty, "TextMuted");
            panel.Children.Add(descBlock);
            item.Content = panel;
        }
        else
        {
            item.Content = model;
        }
        return item;
    }

    // --- Provider UI helpers ---

    private static void LoadProviderCombo(ComboBox combo, IReadOnlyList<ProviderPreset> presets, string selectedType)
    {
        combo.Items.Clear();
        int selectIndex = 0;
        for (int i = 0; i < presets.Count; i++)
        {
            var p = presets[i];
            combo.Items.Add(new ComboBoxItem { Content = p.DisplayName, Tag = p.Id });
            if (p.Id == selectedType)
                selectIndex = i;
        }
        combo.SelectedIndex = selectIndex;
    }

    private void LoadModelCombo(ComboBox combo, ProviderPreset? preset, string currentModel)
    {
        bool wasLoading = _loading;
        _loading = true;

        // Unhook temporarily to avoid re-entrance during rebuild
        combo.DropDownClosed -= ModelCombo_DropDownClosed;

        combo.Items.Clear();
        if (preset?.SuggestedModels != null)
        {
            foreach (var m in preset.SuggestedModels)
                combo.Items.Add(CreateModelItem(m));
        }

        // If current model isn't in the list, add it
        bool found = false;
        for (int i = 0; i < combo.Items.Count; i++)
        {
            if (combo.Items[i] is ComboBoxItem item && (string)item.Tag == currentModel)
            {
                combo.SelectedIndex = i;
                found = true;
                break;
            }
        }
        if (!found && !string.IsNullOrEmpty(currentModel))
        {
            combo.Items.Add(CreateModelItem(currentModel));
            combo.SelectedIndex = combo.Items.Count - 1;
        }
        else if (!found && combo.Items.Count > 0)
        {
            combo.SelectedIndex = 0;
        }

        // For editable combos, show just the model name in the text box
        if (combo.IsEditable)
        {
            var selectedModel = currentModel;
            if (string.IsNullOrEmpty(selectedModel) && combo.SelectedItem is ComboBoxItem sel)
                selectedModel = (string)sel.Tag;
            combo.Text = selectedModel ?? "";
        }

        // Hook to fix text display after dropdown selection
        combo.DropDownClosed += ModelCombo_DropDownClosed;

        _loading = wasLoading;
    }

    private void ModelCombo_DropDownClosed(object? sender, EventArgs e)
    {
        if (sender is ComboBox combo && combo.IsEditable && combo.SelectedItem is ComboBoxItem item)
        {
            // Show just the model name, not the rich panel's ToString()
            combo.Text = (string)item.Tag;
        }
    }

    private ProviderPreset? GetSelectedPreset(ComboBox combo, IReadOnlyList<ProviderPreset> presets)
    {
        if (combo.SelectedItem is ComboBoxItem item)
        {
            var id = (string)item.Tag;
            return presets.FirstOrDefault(p => p.Id == id);
        }
        return null;
    }

    private void UpdateSttProviderUI()
    {
        var s = _settings.Current;
        var preset = GetSelectedPreset(SttProviderCombo, ApiProviders.SttPresets);

        // Capability hint is set by UpdateLlmProviderUI (depends on both providers)
        // Clear it here; it will be set when UpdateLlmProviderUI runs
        SttCapabilityHint.Text = "";

        // API key visibility
        bool needsKey = preset != null && ApiProviders.RequiresApiKey(preset.Id);
        SttApiKeyPanel.Visibility = needsKey ? Visibility.Visible : Visibility.Collapsed;
        if (needsKey)
        {
            var slot = s.SttProvider.ApiKeySlot;
            if (_credStore.HasApiKey(slot))
            {
                SttApiKeyBox.Password = "••••••••••••••••";
                SttApiKeyStatus.Text = $"API key saved ({slot}).";
            }
            else
            {
                SttApiKeyBox.Password = "";
                SttApiKeyStatus.Text = $"No API key configured for {preset?.DisplayName ?? slot}.";
            }
        }

        // Base URL
        SttBaseUrlBox.Text = s.SttProvider.BaseUrl ?? "";
        SttBaseUrlHint.Text = preset != null ? $"Default: {preset.DefaultBaseUrl}" : "";

        // Show base URL field for custom providers or if user has set an override
        bool showBaseUrl = preset?.Id == "custom" || !string.IsNullOrEmpty(s.SttProvider.BaseUrl);
        SttBaseUrlPanel.Visibility = showBaseUrl ? Visibility.Visible : Visibility.Collapsed;

        // Model combo
        LoadModelCombo(SttModelCombo, preset, s.SttProvider.Model);
    }

    private void UpdateLlmProviderUI()
    {
        var s = _settings.Current;
        var preset = GetSelectedPreset(LlmProviderCombo, ApiProviders.LlmPresets);
        var sttPreset = GetSelectedPreset(SttProviderCombo, ApiProviders.SttPresets);

        // Capability hint: show when both STT and LLM use a provider that supports both
        if (sttPreset != null && sttPreset.SupportsStt && sttPreset.SupportsLlm
            && s.SttProvider.ProviderType == s.LlmProvider.ProviderType)
        {
            SttCapabilityHint.Text = $"{sttPreset.DisplayName} supports both STT + LLM";
        }
        else
        {
            SttCapabilityHint.Text = "";
        }

        bool needsKey = preset != null && ApiProviders.RequiresApiKey(preset.Id);

        // Sharing is only possible when the LLM provider type matches the STT provider type
        // (e.g., both "openai", both "groq", both "gemini")
        bool canShare = needsKey
            && s.SttProvider.ProviderType == s.LlmProvider.ProviderType;

        // If sharing not possible, force it off
        if (!canShare && s.UseSharedApiKey)
        {
            s.UseSharedApiKey = false;
            _ = _settings.SaveAsync();
        }

        UseSharedApiKeyCheck.IsChecked = s.UseSharedApiKey;
        UseSharedApiKeyCheck.Content = "Use same API key for LLM";
        UseSharedApiKeyCheck.Visibility = canShare ? Visibility.Visible : Visibility.Collapsed;

        // Show separate LLM key panel when key is needed and not shared
        bool showLlmKey = needsKey && !s.UseSharedApiKey;
        LlmApiKeyPanel.Visibility = showLlmKey ? Visibility.Visible : Visibility.Collapsed;

        if (showLlmKey)
        {
            var slot = s.LlmProvider.ApiKeySlot;
            if (_credStore.HasApiKey(slot))
            {
                LlmApiKeyBox.Password = "••••••••••••••••";
                LlmApiKeyStatus.Text = $"API key saved ({slot}).";
            }
            else
            {
                LlmApiKeyBox.Password = "";
                LlmApiKeyStatus.Text = $"No API key configured for {preset?.DisplayName ?? slot}.";
            }
        }

        // Base URL
        LlmBaseUrlBox.Text = s.LlmProvider.BaseUrl ?? "";
        LlmBaseUrlHint.Text = preset != null ? $"Default: {preset.DefaultBaseUrl}" : "";

        bool showBaseUrl = preset?.Id == "custom" || !string.IsNullOrEmpty(s.LlmProvider.BaseUrl);
        LlmBaseUrlPanel.Visibility = showBaseUrl ? Visibility.Visible : Visibility.Collapsed;

        // Model combo
        LoadModelCombo(LlmModelCombo, preset, s.LlmProvider.Model);
    }

    private async void UseSharedApiKey_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Current.UseSharedApiKey = UseSharedApiKeyCheck.IsChecked == true;
        await _settings.SaveAsync();
        UpdateLlmProviderUI();
    }

    // --- Provider change handlers ---

    private async void SttProvider_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || SttProviderCombo.SelectedItem is not ComboBoxItem item) return;
        var providerType = (string)item.Tag;

        _settings.Current.SttProvider.ProviderType = providerType;
        // Update API key slot to match provider (so each provider has its own key)
        _settings.Current.SttProvider.ApiKeySlot = providerType == "openai" ? "default" : providerType;
        // Clear custom base URL when switching providers (use default)
        _settings.Current.SttProvider.BaseUrl = null;

        // Set default model for new provider
        var preset = ApiProviders.SttPresets.FirstOrDefault(p => p.Id == providerType);
        if (preset?.SuggestedModels.Length > 0)
            _settings.Current.SttProvider.Model = preset.SuggestedModels[0];

        await _settings.SaveAsync();
        UpdateSttProviderUI();
        UpdateLlmProviderUI(); // Re-evaluate shared key possibility
    }

    private async void LlmProvider_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || LlmProviderCombo.SelectedItem is not ComboBoxItem item) return;
        var providerType = (string)item.Tag;

        _settings.Current.LlmProvider.ProviderType = providerType;
        _settings.Current.LlmProvider.ApiKeySlot = providerType == "openai" ? "default" : providerType;
        _settings.Current.LlmProvider.BaseUrl = null;

        var preset = ApiProviders.LlmPresets.FirstOrDefault(p => p.Id == providerType);
        if (preset?.SuggestedModels.Length > 0)
            _settings.Current.LlmProvider.Model = preset.SuggestedModels[0];

        await _settings.SaveAsync();
        UpdateLlmProviderUI();
    }

    private void SaveSttApiKey_Click(object sender, RoutedEventArgs e)
    {
        SaveProviderApiKey(SttApiKeyBox, _settings.Current.SttProvider, SttApiKeyStatus,
            GetSelectedPreset(SttProviderCombo, ApiProviders.SttPresets));
    }

    private void SaveLlmApiKey_Click(object sender, RoutedEventArgs e)
    {
        SaveProviderApiKey(LlmApiKeyBox, _settings.Current.LlmProvider, LlmApiKeyStatus,
            GetSelectedPreset(LlmProviderCombo, ApiProviders.LlmPresets));
    }

    private void SaveProviderApiKey(PasswordBox box, ApiProviderConfig config, TextBlock status, ProviderPreset? preset)
    {
        // Strip any leftover placeholder dots that may have been appended
        // to a paste, then trim whitespace.
        var key = box.Password.Replace("•", "").Trim();
        if (string.IsNullOrEmpty(key))
        {
            status.Text = "Please enter an API key.";
            return;
        }

        _credStore.SaveApiKey(key, config.ApiKeySlot);
        status.Text = $"API key saved securely ({config.ApiKeySlot}).";
        box.Password = "••••••••••••••••";
    }

    private void ApiKeyBox_GotFocus(object sender, RoutedEventArgs e)
    {
        if (sender is PasswordBox box && box.Password.All(c => c == '•'))
            box.Password = "";
    }

    private async void SttBaseUrl_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var url = SttBaseUrlBox.Text.Trim();
        _settings.Current.SttProvider.BaseUrl = string.IsNullOrEmpty(url) ? null : url;
        await _settings.SaveAsync();
    }

    private async void LlmBaseUrl_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var url = LlmBaseUrlBox.Text.Trim();
        _settings.Current.LlmProvider.BaseUrl = string.IsNullOrEmpty(url) ? null : url;
        await _settings.SaveAsync();
    }

    private async void SttModel_Changed(object sender, EventArgs e)
    {
        if (_loading) return;
        string? model = null;
        if (SttModelCombo.SelectedItem is ComboBoxItem item)
            model = (string)item.Tag;
        else if (SttModelCombo.IsEditable && !string.IsNullOrEmpty(SttModelCombo.Text))
            model = SttModelCombo.Text.Trim();

        if (!string.IsNullOrEmpty(model) && model != _settings.Current.SttProvider.Model)
        {
            _settings.Current.SttProvider.Model = model;
            await _settings.SaveAsync();
        }
    }

    private async void LlmModel_Changed(object sender, EventArgs e)
    {
        if (_loading) return;
        string? model = null;
        if (LlmModelCombo.SelectedItem is ComboBoxItem item)
            model = (string)item.Tag;
        else if (LlmModelCombo.IsEditable && !string.IsNullOrEmpty(LlmModelCombo.Text))
            model = LlmModelCombo.Text.Trim();

        if (!string.IsNullOrEmpty(model) && model != _settings.Current.LlmProvider.Model)
        {
            _settings.Current.LlmProvider.Model = model;
            await _settings.SaveAsync();
        }
    }

    // --- Backward-compat: hidden ApiKeyBox for migration ---
    private void SaveApiKey_Click(object sender, RoutedEventArgs e) { }

    private static void SelectComboByTag(ComboBox combo, string tag)
    {
        for (int i = 0; i < combo.Items.Count; i++)
        {
            if (combo.Items[i] is ComboBoxItem item && (string)item.Tag == tag)
            {
                combo.SelectedIndex = i;
                return;
            }
        }
        if (combo.Items.Count > 0) combo.SelectedIndex = 0;
    }

    // --- Hotkey capture ---

    private void HoldToTalkBtn_Click(object sender, RoutedEventArgs e) =>
        StartCapture(HoldToTalkBtn, "hold");

    private void ToggleRecordingBtn_Click(object sender, RoutedEventArgs e) =>
        StartCapture(ToggleRecordingBtn, "toggle");

    private void PasteLastBtn_Click(object sender, RoutedEventArgs e) =>
        StartCapture(PasteLastBtn, "paste");

    private void StartCapture(Button btn, string target)
    {
        if (_capturingButton != null && _capturingButton != btn)
            CancelCapture();

        _capturingButton = btn;
        _capturingTarget = target;
        _capturedModifiers = 0;
        _capturedKeyCode = 0;

        btn.Content = "Press keys...";
        btn.BorderBrush = FindResource("AccentBlue") as System.Windows.Media.SolidColorBrush;

        _hotkeyService?.Pause();

        PreviewKeyDown += OnCaptureKeyDown;
        PreviewKeyUp += OnCaptureKeyUp;
    }

    private void CancelCapture()
    {
        if (_capturingButton == null) return;

        PreviewKeyDown -= OnCaptureKeyDown;
        PreviewKeyUp -= OnCaptureKeyUp;

        var s = _settings.Current;
        switch (_capturingTarget)
        {
            case "hold": _capturingButton.Content = s.HoldToTalkHotkey.DisplayName; break;
            case "toggle": _capturingButton.Content = s.ToggleRecordingHotkey.DisplayName; break;
            case "paste": _capturingButton.Content = s.PasteLastTranscriptHotkey.DisplayName; break;
            case "prompt":
                if (_capturingPromptIndex >= 0 && _capturingPromptIndex < s.Prompts.Count)
                {
                    var p = s.Prompts[_capturingPromptIndex];
                    _capturingButton.Content = p.Hotkey?.DisplayName ?? $"Ctrl+Shift+{_capturingPromptIndex + 1}";
                }
                _capturingPromptIndex = -1;
                break;
        }

        _capturingButton.BorderBrush = FindResource("BorderColor") as System.Windows.Media.SolidColorBrush;
        _capturingButton = null;
        _capturingTarget = null;

        _hotkeyService?.Resume();
    }

    private void OnCaptureKeyDown(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;

        if (key == Key.Escape)
        {
            CancelCapture();
            return;
        }

        // Ignore modifier-only presses, just update display
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift
            or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin)
        {
            UpdateCaptureDisplay();
            return;
        }

        // Non-modifier key pressed — capture and auto-confirm immediately
        _capturedModifiers = GetCurrentModifiers();
        _capturedKeyCode = (uint)KeyInterop.VirtualKeyFromKey(key);
        ConfirmCapture();
    }

    private void OnCaptureKeyUp(object sender, KeyEventArgs e)
    {
        e.Handled = true;
    }

    private void UpdateCaptureDisplay()
    {
        var parts = new List<string>();
        if (Keyboard.IsKeyDown(Key.LeftCtrl) || Keyboard.IsKeyDown(Key.RightCtrl)) parts.Add("Ctrl");
        if (Keyboard.IsKeyDown(Key.LeftShift) || Keyboard.IsKeyDown(Key.RightShift)) parts.Add("Shift");
        if (Keyboard.IsKeyDown(Key.LeftAlt) || Keyboard.IsKeyDown(Key.RightAlt)) parts.Add("Alt");
        if (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin)) parts.Add("Win");

        if (_capturingButton != null)
            _capturingButton.Content = parts.Count > 0
                ? string.Join(" + ", parts) + " + ..."
                : "Press keys...";
    }

    private static uint GetCurrentModifiers()
    {
        uint mods = 0;
        if (Keyboard.IsKeyDown(Key.LeftCtrl) || Keyboard.IsKeyDown(Key.RightCtrl))
            mods |= 0x0002;
        if (Keyboard.IsKeyDown(Key.LeftShift) || Keyboard.IsKeyDown(Key.RightShift))
            mods |= 0x0004;
        if (Keyboard.IsKeyDown(Key.LeftAlt) || Keyboard.IsKeyDown(Key.RightAlt))
            mods |= 0x0001;
        if (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin))
            mods |= 0x0008;
        return mods;
    }

    private static string BuildDisplayName(uint modifiers, Key key)
    {
        var parts = new List<string>();
        if ((modifiers & 0x0002) != 0) parts.Add("Ctrl");
        if ((modifiers & 0x0004) != 0) parts.Add("Shift");
        if ((modifiers & 0x0001) != 0) parts.Add("Alt");
        if ((modifiers & 0x0008) != 0) parts.Add("Win");
        parts.Add(key.ToString());
        return string.Join(" + ", parts);
    }

    private async void ConfirmCapture()
    {
        if (_capturingButton == null || _capturingTarget == null) return;

        var displayName = BuildDisplayName(_capturedModifiers,
            KeyInterop.KeyFromVirtualKey((int)_capturedKeyCode));

        var binding = new HotkeyBinding
        {
            Modifiers = _capturedModifiers,
            KeyCode = _capturedKeyCode,
            DisplayName = displayName
        };

        switch (_capturingTarget)
        {
            case "hold":
                _settings.Current.HoldToTalkHotkey = binding;
                break;
            case "toggle":
                _settings.Current.ToggleRecordingHotkey = binding;
                break;
            case "paste":
                _settings.Current.PasteLastTranscriptHotkey = binding;
                break;
            case "prompt":
                if (_capturingPromptIndex >= 0 && _capturingPromptIndex < _settings.Current.Prompts.Count)
                    _settings.Current.Prompts[_capturingPromptIndex].Hotkey = binding;
                _capturingPromptIndex = -1;
                break;
        }

        await _settings.SaveAsync();

        // Unhook capture handlers BEFORE resuming hotkeys
        PreviewKeyDown -= OnCaptureKeyDown;
        PreviewKeyUp -= OnCaptureKeyUp;

        // Re-register all hotkeys with updated settings
        if (_hotkeyService != null)
        {
            // UnregisterAll + re-register fresh to apply new bindings
            _hotkeyService.UnregisterAll();

            var s = _settings.Current;
            _hotkeyService.StartHoldToTalkListening(s.HoldToTalkHotkey.Modifiers, s.HoldToTalkHotkey.KeyCode);
            _hotkeyService.RegisterToggleRecording(s.ToggleRecordingHotkey.Modifiers, s.ToggleRecordingHotkey.KeyCode);
            _hotkeyService.RegisterPasteLastTranscript(s.PasteLastTranscriptHotkey.Modifiers, s.PasteLastTranscriptHotkey.KeyCode);
            var enabledPrompts = s.Prompts.Where(p => p.Enabled).ToList();
            if (enabledPrompts.Count > 0)
                _hotkeyService.RegisterPromptHotkeys(enabledPrompts.Select(p => p.Hotkey).ToList());

            // Resume sets _paused = false (hotkeys already registered above, Resume's re-registration will be no-ops)
            _hotkeyService.Resume();
        }

        _capturingButton.Content = displayName;
        _capturingButton.BorderBrush = FindResource("BorderColor") as System.Windows.Media.SolidColorBrush;
        _capturingButton = null;
        _capturingTarget = null;
    }

    // --- Standard handlers ---

    private async void Microphone_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || MicrophoneCombo.SelectedItem is not ComboBoxItem item) return;
        _settings.Current.SelectedMicrophoneIndex = (int)item.Tag;
        await _settings.SaveAsync();
    }

    private async void OutputMode_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || OutputModeCombo.SelectedItem is not ComboBoxItem item) return;
        _settings.Current.OutputMode = (string)item.Tag;
        await _settings.SaveAsync();
    }

    private async void Language_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || LanguageCombo.SelectedItem is not ComboBoxItem item) return;
        var lang = (string)item.Tag;
        _settings.Current.LanguageHint = string.IsNullOrEmpty(lang) ? null : lang;
        await _settings.SaveAsync();
    }

    private async void ShowIndicator_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Current.ShowRecordingIndicator = ShowIndicatorCheck.IsChecked == true;
        await _settings.SaveAsync();
    }

    private async void RestoreClipboard_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Current.RestoreClipboard = RestoreClipboardCheck.IsChecked == true;
        await _settings.SaveAsync();
    }

    private async void LaunchOnStartup_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        bool enable = LaunchOnStartupCheck.IsChecked == true;
        _settings.Current.LaunchOnStartup = enable;
        await _settings.SaveAsync();
        SetStartupRegistry(enable);
    }

    private static void SetStartupRegistry(bool enable)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Run", true);
            if (enable)
            {
                var exePath = Environment.ProcessPath ?? "";
                key?.SetValue("STTpro", $"\"{exePath}\"");
            }
            else
            {
                key?.DeleteValue("STTpro", false);
            }
        }
        catch { /* May fail in some environments */ }
    }

    // --- Usage ---

    private void LoadUsageStats()
    {
        var u = _settings.Current.Usage;
        UsageCountLabel.Text = u.TranscriptionCount.ToString();
        UsageMinutesLabel.Text = u.TotalAudioMinutes.ToString("F1");
        var totalCost = u.TotalWhisperCost + u.TotalPostProcessCost;
        UsageCostLabel.Text = $"${totalCost:F4}";

        if (u.PostProcessTokensIn > 0 || u.PostProcessTokensOut > 0)
            UsageDetailsLabel.Text = $"STT: ${u.TotalWhisperCost:F4}  |  LLM: ${u.TotalPostProcessCost:F4} ({u.PostProcessTokensIn} in / {u.PostProcessTokensOut} out)";
        else
            UsageDetailsLabel.Text = "";
    }

    private async void ResetUsage_Click(object sender, RoutedEventArgs e)
    {
        var result = MessageBox.Show("Reset all usage statistics?", "Reset Usage",
            MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (result != MessageBoxResult.Yes) return;

        _settings.Current.Usage = new UsageStats();
        await _settings.SaveAsync();
        LoadUsageStats();
    }

    // --- Smart Prompts ---

    private void LoadPrompts()
    {
        // Set prompt hotkey mode radio buttons
        if (_settings.Current.PromptHotkeyMode == "hold")
            PromptModeHold.IsChecked = true;
        else
            PromptModeToggle.IsChecked = true;

        RenderPromptList();
    }

    private async void PromptMode_Changed(object sender, RoutedEventArgs e)
    {
        var mode = PromptModeHold.IsChecked == true ? "hold" : "toggle";
        if (_settings.Current.PromptHotkeyMode == mode) return;
        _settings.Current.PromptHotkeyMode = mode;
        await _settings.SaveAsync();

        // Update the GlobalHotkeyService's hold mode flag
        if (_hotkeyService is GlobalHotkeyService ghs)
            ghs.PromptHoldMode = mode == "hold";
    }

    private int _capturingPromptIndex = -1;

    private void StartPromptHotkeyCapture(Button btn, int promptIndex)
    {
        if (_capturingButton != null && _capturingButton != btn)
            CancelCapture();

        _capturingButton = btn;
        _capturingTarget = "prompt";
        _capturingPromptIndex = promptIndex;
        _capturedModifiers = 0;
        _capturedKeyCode = 0;

        btn.Content = "Press keys...";
        btn.BorderBrush = FindResource("AccentBlue") as System.Windows.Media.SolidColorBrush;

        _hotkeyService?.Pause();

        PreviewKeyDown += OnCaptureKeyDown;
        PreviewKeyUp += OnCaptureKeyUp;
    }

    private void RenderPromptList()
    {
        PromptsPanel.Items.Clear();
        var prompts = _settings.Current.Prompts;
        for (int i = 0; i < prompts.Count; i++)
        {
            var prompt = prompts[i];
            var idx = i;

            var card = new Border
            {
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(14, 12, 14, 12),
                Margin = new Thickness(0, 0, 0, 10)
            };
            card.SetResourceReference(Border.BackgroundProperty, "BgInput");

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var left = new StackPanel();
            var header = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };

            var hotkeyDisplay = prompt.Hotkey?.DisplayName ?? $"Ctrl+Shift+{i + 1}";
            var hotkeyBtn = new Button
            {
                Content = hotkeyDisplay,
                FontSize = 10,
                FontFamily = new System.Windows.Media.FontFamily("Cascadia Code, Consolas"),
                Style = FindResource("MiniButton") as Style,
                BorderThickness = new Thickness(1),
                Padding = new Thickness(7, 2, 7, 2),
                Margin = new Thickness(0, 0, 6, 0),
                Cursor = System.Windows.Input.Cursors.Hand,
                ToolTip = "Click to rebind hotkey"
            };
            hotkeyBtn.SetResourceReference(Button.ForegroundProperty, "AccentBlue");
            hotkeyBtn.SetResourceReference(Button.BorderBrushProperty, "AccentBorderSubtle");
            var hkIdx = idx;
            hotkeyBtn.Click += (_, _) => StartPromptHotkeyCapture(hotkeyBtn, hkIdx);
            header.Children.Add(hotkeyBtn);

            var nameBox = new TextBox
            {
                Text = prompt.Name,
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Background = System.Windows.Media.Brushes.Transparent,
                BorderThickness = new Thickness(0, 0, 0, 1),
                Padding = new Thickness(2, 0, 2, 1),
                MinWidth = 100,
                VerticalContentAlignment = VerticalAlignment.Center,
                ToolTip = "Click to edit name"
            };
            nameBox.SetResourceReference(TextBox.BorderBrushProperty, "AccentBorderSubtle");
            var nameIdx = idx;
            nameBox.LostFocus += async (_, _) =>
            {
                if (nameIdx < _settings.Current.Prompts.Count)
                {
                    _settings.Current.Prompts[nameIdx].Name = nameBox.Text;
                    await _settings.SaveAsync();
                }
            };
            header.Children.Add(nameBox);
            left.Children.Add(header);

            var promptBox = new TextBox
            {
                Text = prompt.Prompt,
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                MaxHeight = 72,
                BorderThickness = new Thickness(1),
                Padding = new Thickness(7, 5, 7, 5),
                AcceptsReturn = true,
                ToolTip = "Click to edit prompt text",
                Margin = new Thickness(0, 2, 0, 0)
            };
            promptBox.SetResourceReference(TextBox.BackgroundProperty, "BgCard");
            promptBox.SetResourceReference(TextBox.BorderBrushProperty, "BorderColor");
            promptBox.SetResourceReference(TextBox.ForegroundProperty, "TextSecondary");
            var promptIdx = idx;
            promptBox.LostFocus += async (_, _) =>
            {
                if (promptIdx < _settings.Current.Prompts.Count)
                {
                    _settings.Current.Prompts[promptIdx].Prompt = promptBox.Text;
                    await _settings.SaveAsync();
                }
            };
            left.Children.Add(promptBox);

            Grid.SetColumn(left, 0);
            grid.Children.Add(left);

            // Right side: revert hotkey + remove buttons
            var rightPanel = new StackPanel { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8, 0, 0, 0) };

            var revertHkBtn = new Button
            {
                Content = "Reset",
                FontSize = 10,
                Style = FindResource("MiniButton") as Style,
                Padding = new Thickness(8, 3, 8, 3),
                Margin = new Thickness(0, 0, 0, 5),
                Cursor = System.Windows.Input.Cursors.Hand,
                ToolTip = $"Reset to Ctrl+Shift+{idx + 1}"
            };
            revertHkBtn.SetResourceReference(Button.ForegroundProperty, "TextMuted");
            var revertIdx = idx;
            revertHkBtn.Click += async (_, _) =>
            {
                if (revertIdx < _settings.Current.Prompts.Count)
                {
                    _settings.Current.Prompts[revertIdx].Hotkey = null;
                    await _settings.SaveAsync();
                    ReRegisterAllHotkeys();
                    RenderPromptList();
                }
            };
            rightPanel.Children.Add(revertHkBtn);

            var removeBtn = new Button
            {
                Content = "×",
                FontSize = 14,
                FontWeight = FontWeights.Bold,
                Style = FindResource("MiniButton") as Style,
                Padding = new Thickness(9, 1, 9, 2),
                Cursor = System.Windows.Input.Cursors.Hand,
                ToolTip = "Remove prompt"
            };
            removeBtn.SetResourceReference(Button.ForegroundProperty, "AccentRed");
            var removeIdx = idx;
            removeBtn.Click += async (_, _) =>
            {
                if (removeIdx < _settings.Current.Prompts.Count)
                {
                    _settings.Current.Prompts.RemoveAt(removeIdx);
                    await _settings.SaveAsync();
                    RenderPromptList();
                }
            };
            rightPanel.Children.Add(removeBtn);
            Grid.SetColumn(rightPanel, 1);
            grid.Children.Add(rightPanel);

            card.Child = grid;
            PromptsPanel.Items.Add(card);
        }
    }

    private async void AddPrompt_Click(object sender, RoutedEventArgs e)
    {
        _settings.Current.Prompts.Add(new PromptTemplate
        {
            Name = "New Prompt",
            Prompt = "Process this transcription. Output only the result.",
            Enabled = true
        });
        await _settings.SaveAsync();
        RenderPromptList();
    }

    // --- History Tab ---

    private async Task LoadHistoryAsync()
    {
        if (_history == null) return;

        var records = await _history.GetRecentAsync(200);
        RenderHistoryList(records);
    }

    private void RenderHistoryList(IReadOnlyList<TranscriptRecord> records)
    {
        HistoryList.Items.Clear();
        foreach (var r in records)
        {
            var sp = new StackPanel { Margin = new Thickness(0) };
            sp.Tag = r; // store full record for copy/delete/export

            var headerPanel = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            var tsBlock = new TextBlock
            {
                Text = r.Timestamp.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss"),
                FontSize = 10,
                Margin = new Thickness(0, 0, 8, 0),
                VerticalAlignment = VerticalAlignment.Center
            };
            tsBlock.SetResourceReference(TextBlock.ForegroundProperty, "TextMuted");
            headerPanel.Children.Add(tsBlock);
            if (!string.IsNullOrEmpty(r.DetectedLanguage))
            {
                var langBorder = new Border
                {
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(6, 1, 6, 1),
                    Margin = new Thickness(0, 0, 8, 0),
                    VerticalAlignment = VerticalAlignment.Center
                };
                langBorder.SetResourceReference(Border.BackgroundProperty, "BadgeBlueBg");
                var langText = new TextBlock { Text = r.DetectedLanguage, FontSize = 10 };
                langText.SetResourceReference(TextBlock.ForegroundProperty, "AccentBlue");
                langBorder.Child = langText;
                headerPanel.Children.Add(langBorder);
            }
            var durBlock = new TextBlock
            {
                Text = $"{r.DurationSeconds:F1}s",
                FontSize = 10,
                VerticalAlignment = VerticalAlignment.Center
            };
            durBlock.SetResourceReference(TextBlock.ForegroundProperty, "TextMuted");
            headerPanel.Children.Add(durBlock);
            // Show prompt badge if used
            if (!string.IsNullOrEmpty(r.PromptName))
            {
                var promptBorder = new Border
                {
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(6, 1, 6, 1),
                    Margin = new Thickness(8, 0, 0, 0),
                    VerticalAlignment = VerticalAlignment.Center
                };
                promptBorder.SetResourceReference(Border.BackgroundProperty, "BadgeOrangeBg");
                var promptText = new TextBlock { Text = r.PromptName, FontSize = 10 };
                promptText.SetResourceReference(TextBlock.ForegroundProperty, "AccentOrange");
                promptBorder.Child = promptText;
                headerPanel.Children.Add(promptBorder);
            }
            sp.Children.Add(headerPanel);

            // Show original text if post-processed
            if (!string.IsNullOrEmpty(r.OriginalText))
            {
                var origPreview = r.OriginalText.Length > 100 ? r.OriginalText[..100] + "..." : r.OriginalText;
                var origBlock = new TextBlock
                {
                    Text = $"Original: {origPreview}",
                    FontSize = 10,
                    TextWrapping = TextWrapping.Wrap,
                    MaxHeight = 28,
                    Margin = new Thickness(0, 2, 0, 0),
                    FontStyle = System.Windows.FontStyles.Italic
                };
                origBlock.SetResourceReference(TextBlock.ForegroundProperty, "TextMuted");
                sp.Children.Add(origBlock);
            }

            var textPreview = r.Text.Length > 200 ? r.Text[..200] + "..." : r.Text;
            var textBlock = new TextBlock
            {
                Text = textPreview,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                MaxHeight = 54,
                Margin = new Thickness(0, 3, 0, 0)
            };
            textBlock.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimary");
            sp.Children.Add(textBlock);

            HistoryList.Items.Add(sp);
        }
    }

    private async void HistorySearch_Click(object sender, RoutedEventArgs e)
    {
        await SearchHistoryAsync();
    }

    private async Task SearchHistoryAsync()
    {
        if (_history == null) return;
        var query = HistorySearchBox.Text.Trim();
        if (string.IsNullOrEmpty(query))
        {
            await LoadHistoryAsync();
            return;
        }
        var results = await _history.SearchAsync(query);
        RenderHistoryList(results);
    }

    private void HistoryCopy_Click(object sender, RoutedEventArgs e)
    {
        if (HistoryList.SelectedItem is StackPanel sp && sp.Tag is TranscriptRecord record)
        {
            Clipboard.SetText(record.Text);
        }
    }

    private async void HistoryDelete_Click(object sender, RoutedEventArgs e)
    {
        if (_history == null) return;
        if (HistoryList.SelectedItem is StackPanel sp && sp.Tag is TranscriptRecord record)
        {
            await _history.DeleteAsync(record.Id);
            await LoadHistoryAsync();
        }
    }

    private async void HistoryRefresh_Click(object sender, RoutedEventArgs e)
    {
        HistorySearchBox.Clear();
        await LoadHistoryAsync();
    }

    private async void ExportJson_Click(object sender, RoutedEventArgs e)
    {
        if (_history == null) return;

        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "JSON files (*.json)|*.json",
            FileName = $"STTpro_export_{DateTime.Now:yyyyMMdd_HHmmss}.json",
            DefaultExt = ".json"
        };
        if (dialog.ShowDialog() != true) return;

        var records = await _history.GetRecentAsync(10000);
        var exportData = records.Select(r => new
        {
            r.Id,
            Timestamp = r.Timestamp.ToString("O"),
            r.Text,
            Language = r.DetectedLanguage,
            Duration = r.DurationSeconds,
            r.ProviderName,
            r.TargetWindowName
        });

        var json = JsonSerializer.Serialize(exportData, new JsonSerializerOptions { WriteIndented = true });
        await File.WriteAllTextAsync(dialog.FileName, json, Encoding.UTF8);
        MessageBox.Show($"Exported {records.Count} transcripts to:\n{dialog.FileName}", "Export Complete",
            MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private async void ExportText_Click(object sender, RoutedEventArgs e)
    {
        if (_history == null) return;

        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "Text files (*.txt)|*.txt",
            FileName = $"STTpro_export_{DateTime.Now:yyyyMMdd_HHmmss}.txt",
            DefaultExt = ".txt"
        };
        if (dialog.ShowDialog() != true) return;

        var records = await _history.GetRecentAsync(10000);
        var sb = new StringBuilder();
        foreach (var r in records)
        {
            sb.AppendLine($"[{r.Timestamp.ToLocalTime():yyyy-MM-dd HH:mm:ss}] ({r.DetectedLanguage}, {r.DurationSeconds:F1}s)");
            sb.AppendLine(r.Text);
            sb.AppendLine(new string('-', 60));
            sb.AppendLine();
        }

        await File.WriteAllTextAsync(dialog.FileName, sb.ToString(), Encoding.UTF8);
        MessageBox.Show($"Exported {records.Count} transcripts to:\n{dialog.FileName}", "Export Complete",
            MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private async void HistoryRetention_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || HistoryRetentionCombo.SelectedItem is not ComboBoxItem item) return;
        _settings.Current.MaxHistoryItems = int.Parse((string)item.Tag);
        await _settings.SaveAsync();
    }

    // --- Hotkey revert handlers ---

    private async void RevertHoldToTalk_Click(object sender, RoutedEventArgs e)
    {
        var def = AppSettings.DefaultHoldToTalk;
        _settings.Current.HoldToTalkHotkey = new HotkeyBinding
            { Modifiers = def.Modifiers, KeyCode = def.KeyCode, DisplayName = def.DisplayName };
        await _settings.SaveAsync();
        HoldToTalkBtn.Content = def.DisplayName;
        ReRegisterAllHotkeys();
    }

    private async void RevertToggleRecording_Click(object sender, RoutedEventArgs e)
    {
        var def = AppSettings.DefaultToggleRecording;
        _settings.Current.ToggleRecordingHotkey = new HotkeyBinding
            { Modifiers = def.Modifiers, KeyCode = def.KeyCode, DisplayName = def.DisplayName };
        await _settings.SaveAsync();
        ToggleRecordingBtn.Content = def.DisplayName;
        ReRegisterAllHotkeys();
    }

    private async void RevertPasteLast_Click(object sender, RoutedEventArgs e)
    {
        var def = AppSettings.DefaultPasteLastTranscript;
        _settings.Current.PasteLastTranscriptHotkey = new HotkeyBinding
            { Modifiers = def.Modifiers, KeyCode = def.KeyCode, DisplayName = def.DisplayName };
        await _settings.SaveAsync();
        PasteLastBtn.Content = def.DisplayName;
        ReRegisterAllHotkeys();
    }

    private void ReRegisterAllHotkeys()
    {
        if (_hotkeyService == null) return;
        _hotkeyService.UnregisterAll();
        var s = _settings.Current;
        _hotkeyService.StartHoldToTalkListening(s.HoldToTalkHotkey.Modifiers, s.HoldToTalkHotkey.KeyCode);
        _hotkeyService.RegisterToggleRecording(s.ToggleRecordingHotkey.Modifiers, s.ToggleRecordingHotkey.KeyCode);
        _hotkeyService.RegisterPasteLastTranscript(s.PasteLastTranscriptHotkey.Modifiers, s.PasteLastTranscriptHotkey.KeyCode);
        var enabledPrompts = s.Prompts.Where(p => p.Enabled).ToList();
        if (enabledPrompts.Count > 0)
            _hotkeyService.RegisterPromptHotkeys(enabledPrompts.Select(p => p.Hotkey).ToList());
    }

    // --- Silence & trailing period ---

    private async void SilenceSlider_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading) return;
        var val = Math.Round(SilenceSlider.Value, 2);
        _settings.Current.SilenceThreshold = val;
        SilenceThresholdLabel.Text = val.ToString("F2");
        await _settings.SaveAsync();
    }

    private async void AddTrailingPeriod_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Current.AddTrailingPeriod = AddTrailingPeriodCheck.IsChecked == true;
        await _settings.SaveAsync();
    }

    private async void SkipShortRecordings_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.Current.SkipShortRecordings = SkipShortRecordingsCheck.IsChecked == true;
        await _settings.SaveAsync();
    }

    // --- Reset to defaults ---

    private async void ResetToDefaults_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ResetSettingsDialog { Owner = this };
        dialog.ShowDialog();
        if (!dialog.Confirmed) return;

        bool resetPrompts = dialog.ResetPrompts;

        // Save current prompts if not resetting them
        var currentPrompts = resetPrompts ? null : _settings.Current.Prompts;
        var currentUsage = _settings.Current.Usage; // always preserve usage

        // Create fresh defaults
        var defaults = AppSettings.CreateDefaults();
        if (!resetPrompts && currentPrompts != null)
            defaults.Prompts = currentPrompts;
        defaults.Usage = currentUsage;

        // Copy defaults to current
        var s = _settings.Current;
        s.SelectedMicrophoneId = defaults.SelectedMicrophoneId;
        s.SelectedMicrophoneIndex = defaults.SelectedMicrophoneIndex;
        s.OutputMode = defaults.OutputMode;
        s.LanguageHint = defaults.LanguageHint;
        s.SttProvider = defaults.SttProvider;
        s.LlmProvider = defaults.LlmProvider;
        s.UseSharedApiKey = defaults.UseSharedApiKey;
        s.HoldToTalkHotkey = defaults.HoldToTalkHotkey;
        s.ToggleRecordingHotkey = defaults.ToggleRecordingHotkey;
        s.PasteLastTranscriptHotkey = defaults.PasteLastTranscriptHotkey;
        s.LaunchOnStartup = defaults.LaunchOnStartup;
        s.ShowRecordingIndicator = defaults.ShowRecordingIndicator;
        s.PlaySoundCues = defaults.PlaySoundCues;
        s.PreRollMs = defaults.PreRollMs;
        s.MaxHistoryItems = defaults.MaxHistoryItems;
        s.RestoreClipboard = defaults.RestoreClipboard;
        s.SilenceThreshold = defaults.SilenceThreshold;
        s.AddTrailingPeriod = defaults.AddTrailingPeriod;
        s.PromptHotkeyMode = defaults.PromptHotkeyMode;
        if (resetPrompts)
            s.Prompts = defaults.Prompts;

        await _settings.SaveAsync();

        // Reload UI
        _loading = true;
        LoadSettings();
        LoadPrompts();
        LoadUsageStats();
        _loading = false;

        ReRegisterAllHotkeys();
    }

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }
}
