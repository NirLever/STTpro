using System.Text;
using STTpro.Core.Audio;
using STTpro.Core.History;
using STTpro.Core.Hotkeys;
using STTpro.Core.Logging;
using STTpro.Core.Notifications;
using STTpro.Core.Output;
using STTpro.Core.Settings;
using STTpro.Core.Stt;
using STTpro.Interop;

namespace STTpro.Core;

public enum AppState
{
    Idle,
    Recording,
    Transcribing,
    PostProcessing
}

public class AppOrchestrator : IDisposable
{
    private readonly IAudioCaptureService _audio;
    private readonly IGlobalHotkeyService _hotkeys;
    private readonly ITextOutputService _output;
    private readonly ITranscriptRepository _history;
    private readonly ISettingsService _settings;
    private readonly SttProviderFactory _sttFactory;
    private readonly INotificationService _notifications;
    private readonly GptPostProcessor _postProcessor;

    private AppState _state = AppState.Idle;
    private bool _isToggleRecording;
    private bool _holdToTalkActive;
    private IntPtr _recordingStartWindowHwnd;
    private int _selectedPromptIndex = -1; // -1 = no prompt, 0+ = prompt index

    // Chunked transcription state
    private readonly List<string> _chunkResults = new();
    private readonly List<Task> _chunkTasks = new();

    public AppState State => _state;
    public IntPtr RecordingTargetHwnd => _recordingStartWindowHwnd;
    public event EventHandler<AppState>? StateChanged;
    public event EventHandler<string?>? PromptChanged;

    /// <summary>Stop recording and transcribe (same as releasing hold-to-talk or toggling off).</summary>
    public async void StopRecordingFromUI()
    {
        if (_state == AppState.Recording)
        {
            FileLogger.Info("Stop recording requested from UI");
            await StopAndTranscribeAsync();
        }
    }

    /// <summary>Cancel recording without transcribing.</summary>
    public void CancelRecordingFromUI()
    {
        if (_state == AppState.Recording)
        {
            FileLogger.Info("Cancel recording requested from UI");
            try
            {
                _ = _audio.StopRecordingAsync(); // discard the audio
            }
            catch (Exception ex)
            {
                FileLogger.Error("Failed to cancel recording", ex);
            }
            _selectedPromptIndex = -1;
            PromptChanged?.Invoke(this, null);
            SetState(AppState.Idle);
        }
    }

    public AppOrchestrator(
        IAudioCaptureService audio,
        IGlobalHotkeyService hotkeys,
        ITextOutputService output,
        ITranscriptRepository history,
        ISettingsService settings,
        SttProviderFactory sttFactory,
        INotificationService notifications,
        GptPostProcessor postProcessor)
    {
        _audio = audio;
        _hotkeys = hotkeys;
        _output = output;
        _history = history;
        _settings = settings;
        _sttFactory = sttFactory;
        _notifications = notifications;
        _postProcessor = postProcessor;
    }

    public async Task InitializeAsync()
    {
        FileLogger.Info("Initializing orchestrator...");

        await _history.EnsureCreatedAsync();
        await _settings.LoadAsync();

        var s = _settings.Current;

        // Configure audio
        if (_audio is NAudioCaptureService nAudio)
            nAudio.Configure(s.PreRollMs);

        // Default to device 0 if none selected
        int micIndex = s.SelectedMicrophoneIndex >= 0 ? s.SelectedMicrophoneIndex : 0;
        _audio.SelectDevice(micIndex);
        FileLogger.Info($"Using microphone device index: {micIndex}");

        // Start listening (fills pre-roll buffer)
        try
        {
            _audio.StartListening();
            FileLogger.Info("Audio listening started.");
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed to start audio listening", ex);
            _notifications.ShowError($"Microphone error: {ex.Message}");
        }

        // Listen for silence to do chunked transcription
        _audio.SilenceDetected += OnSilenceDetected;

        // Register hotkeys
        _hotkeys.HoldToTalkStarted += OnHoldToTalkStarted;
        _hotkeys.HoldToTalkEnded += OnHoldToTalkEnded;
        _hotkeys.ToggleRecordingPressed += OnToggleRecordingPressed;
        _hotkeys.PasteLastTranscriptPressed += OnPasteLastTranscriptPressed;

        _hotkeys.StartHoldToTalkListening(
            s.HoldToTalkHotkey.Modifiers,
            s.HoldToTalkHotkey.KeyCode);
        FileLogger.Info($"Hold-to-talk hotkey: {s.HoldToTalkHotkey.DisplayName}");

        _hotkeys.RegisterToggleRecording(
            s.ToggleRecordingHotkey.Modifiers,
            s.ToggleRecordingHotkey.KeyCode);
        FileLogger.Info($"Toggle recording hotkey: {s.ToggleRecordingHotkey.DisplayName}");

        _hotkeys.RegisterPasteLastTranscript(
            s.PasteLastTranscriptHotkey.Modifiers,
            s.PasteLastTranscriptHotkey.KeyCode);
        FileLogger.Info($"Paste last hotkey: {s.PasteLastTranscriptHotkey.DisplayName}");

        // Register prompt selection hotkeys (Ctrl+Shift+1, Ctrl+Shift+2, ...)
        var enabledPrompts = s.Prompts.Where(p => p.Enabled).ToList();
        if (enabledPrompts.Count > 0)
        {
            _hotkeys.PromptSelected += OnPromptSelected;
            _hotkeys.PromptReleased += OnPromptReleased;
            var bindings = enabledPrompts.Select(p => p.Hotkey).ToList();
            _hotkeys.RegisterPromptHotkeys(bindings);
            FileLogger.Info($"Registered {enabledPrompts.Count} prompt hotkeys, mode={s.PromptHotkeyMode}");
        }

        FileLogger.Info("Orchestrator initialized successfully.");
    }

    private void OnHoldToTalkStarted(object? sender, EventArgs e)
    {
        if (_state != AppState.Idle)
        {
            FileLogger.Info($"Hold-to-talk: key DOWN ignored (state={_state})");
            return;
        }
        FileLogger.Info("Hold-to-talk: key DOWN -> starting recording");
        _isToggleRecording = false;
        _holdToTalkActive = true;
        StartRecording();
    }

    private async void OnHoldToTalkEnded(object? sender, EventArgs e)
    {
        if (!_holdToTalkActive) return;
        _holdToTalkActive = false;

        if (_state != AppState.Recording)
        {
            FileLogger.Info($"Hold-to-talk: key UP ignored (state={_state})");
            return;
        }
        if (_isToggleRecording) return;

        FileLogger.Info("Hold-to-talk: key UP -> stopping recording");
        await StopAndTranscribeAsync();
    }

    private async void OnToggleRecordingPressed(object? sender, EventArgs e)
    {
        if (_state == AppState.Idle)
        {
            FileLogger.Info("Toggle: starting recording");
            _isToggleRecording = true;
            StartRecording();
        }
        else if (_state == AppState.Recording && _isToggleRecording)
        {
            FileLogger.Info("Toggle: stopping recording");
            await StopAndTranscribeAsync();
        }
    }

    private async void OnPromptSelected(object? sender, int promptIndex)
    {
        var enabledPrompts = _settings.Current.Prompts.Where(p => p.Enabled).ToList();
        if (promptIndex < 0 || promptIndex >= enabledPrompts.Count) return;

        bool isHoldMode = _settings.Current.PromptHotkeyMode == "hold";

        // If recording with same prompt in toggle mode, stop and transcribe
        if (_state == AppState.Recording && _selectedPromptIndex == promptIndex && !isHoldMode)
        {
            FileLogger.Info($"Prompt hotkey toggle off: stopping recording with prompt [{promptIndex}]");
            await StopAndTranscribeAsync();
            return;
        }

        // If recording with different prompt, switch prompt
        if (_state == AppState.Recording && _selectedPromptIndex != promptIndex)
        {
            _selectedPromptIndex = promptIndex;
            var switchName = enabledPrompts[promptIndex].Name;
            FileLogger.Info($"Switched prompt during recording: [{promptIndex}] \"{switchName}\"");
            PromptChanged?.Invoke(this, switchName);
            return;
        }

        // If idle, select prompt and start recording
        if (_state == AppState.Idle)
        {
            _selectedPromptIndex = promptIndex;
            var name = enabledPrompts[promptIndex].Name;
            FileLogger.Info($"Prompt selected: [{promptIndex}] \"{name}\" (mode={_settings.Current.PromptHotkeyMode})");
            PromptChanged?.Invoke(this, name);
            _isToggleRecording = !isHoldMode; // hold mode uses release to stop
            StartRecording();
        }
    }

    private async void OnPromptReleased(object? sender, int promptIndex)
    {
        // Only relevant in hold mode — stop recording when key is released
        if (_state != AppState.Recording) return;
        if (_settings.Current.PromptHotkeyMode != "hold") return;

        FileLogger.Info($"Prompt hold released: stopping recording with prompt [{promptIndex}]");
        await StopAndTranscribeAsync();
    }

    private async void OnPasteLastTranscriptPressed(object? sender, EventArgs e)
    {
        if (_state != AppState.Idle) return;

        FileLogger.Info("Paste last transcript hotkey pressed");
        var latest = await _history.GetLatestAsync();
        if (latest == null)
        {
            _notifications.ShowInfo("No transcript in history.");
            return;
        }

        var mode = Enum.Parse<OutputMode>(_settings.Current.OutputMode);
        if (mode == OutputMode.SaveOnly) mode = OutputMode.ClipboardPaste;

        try
        {
            FileLogger.Info($"Pasting last transcript ({latest.Text.Length} chars) via {mode}");
            await _output.InsertTextAsync(latest.Text, mode);
        }
        catch (Exception ex)
        {
            FileLogger.Error("Paste failed", ex);
            _notifications.ShowError($"Paste failed: {ex.Message}");
        }
    }

    private void StartRecording()
    {
        try
        {
            // Capture the target window BEFORE recording starts
            _recordingStartWindowHwnd = NativeMethods.GetForegroundWindow();
            FileLogger.Info($"Captured target window: 0x{_recordingStartWindowHwnd:X} ({GetWindowName(_recordingStartWindowHwnd)})");

            // Clear chunk state
            lock (_chunkResults) { _chunkResults.Clear(); }
            lock (_chunkTasks) { _chunkTasks.Clear(); }

            _audio.StartRecording();
            SetState(AppState.Recording);
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed to start recording", ex);
            _notifications.ShowError($"Recording error: {ex.Message}");
        }
    }

    private void OnSilenceDetected(object? sender, EventArgs e)
    {
        if (_state != AppState.Recording) return;

        var chunk = _audio.SplitRecording();
        if (chunk == null) return;

        FileLogger.Info($"Silence detected — splitting audio chunk ({chunk.Length} bytes) for background transcription");

        var task = TranscribeChunkAsync(chunk);
        lock (_chunkTasks) { _chunkTasks.Add(task); }
    }

    private async Task TranscribeChunkAsync(MemoryStream chunk)
    {
        try
        {
            var provider = _sttFactory.Create();

            var result = await provider.TranscribeAsync(chunk, _settings.Current.LanguageHint);
            chunk.Dispose();

            // Filter silence hallucinations in chunks too
            if (result.NoSpeechProbability > _settings.Current.SilenceThreshold)
            {
                FileLogger.Info($"Chunk skipped: no_speech_prob={result.NoSpeechProbability:F3} (silence/noise)");
            }
            else if (!string.IsNullOrWhiteSpace(result.Text))
            {
                var processed = Stt.PunctuationReplacer.Apply(result.Text);
                lock (_chunkResults)
                {
                    _chunkResults.Add(processed);
                }
                FileLogger.Info($"Chunk transcription complete: \"{processed}\"");
            }
        }
        catch (Exception ex)
        {
            FileLogger.Error("Chunk transcription failed", ex);
            chunk.Dispose();
        }
    }

    private async Task StopAndTranscribeAsync()
    {
        SetState(AppState.Transcribing);

        MemoryStream audioStream;
        try
        {
            audioStream = await _audio.StopRecordingAsync();
            FileLogger.Info($"Recording stopped. Audio size: {audioStream.Length} bytes");
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed to stop recording", ex);
            _notifications.ShowError($"Recording error: {ex.Message}");
            SetState(AppState.Idle);
            return;
        }

        // Use the window name from when recording started
        string targetWindow = GetWindowName(_recordingStartWindowHwnd);
        FileLogger.Info($"Target window: {targetWindow}");

        // Calculate audio duration from stream size: (bytes - 44 header) / (sampleRate * bytesPerSample)
        double audioDurationMs = (audioStream.Length - 44) / (16000.0 * 2) * 1000;
        FileLogger.Info($"Audio duration: {audioDurationMs:F0} ms");

        // Skip short final segments based on user setting (default: skip if < 250 ms).
        // IMPORTANT: even if the final segment is too short, we may have chunks already
        // transcribed from silence splits that we still want to output. Only bail out
        // entirely if there are no chunks and no in-flight chunk tasks.
        int minDurationMs = _settings.Current.SkipShortRecordings ? _settings.Current.MinRecordingDurationMs : 0;
        bool finalTooShort = audioDurationMs < minDurationMs;
        if (finalTooShort)
        {
            int pendingChunks;
            int completedChunks;
            lock (_chunkResults) { completedChunks = _chunkResults.Count; }
            lock (_chunkTasks) { pendingChunks = _chunkTasks.Count(t => !t.IsCompleted); }

            if (completedChunks == 0 && pendingChunks == 0)
            {
                audioStream.Dispose();
                FileLogger.Info($"Recording too short ({audioDurationMs:F0} ms < {minDurationMs} ms) and no chunks, skipping.");
                _notifications.ShowInfo("Recording too short.");
                _selectedPromptIndex = -1;
                PromptChanged?.Invoke(this, null);
                SetState(AppState.Idle);
                return;
            }

            FileLogger.Info($"Final segment too short ({audioDurationMs:F0} ms) but have {completedChunks} completed + {pendingChunks} pending chunks — keeping them.");
            audioStream.Dispose();
            audioStream = new MemoryStream(); // empty stream; we'll skip STT for the final segment
        }

        SttResult? result = null;
        if (finalTooShort)
        {
            // Use an empty silence result — actual text comes from accumulated chunks
            // Confidence=1.0 (we're certain it's empty), NoSpeechProbability=1.0 (treated as silence)
            result = new SttResult("", "", TimeSpan.Zero, 1.0, 1.0);
        }
        else
        try
        {
            var sttConfig = _settings.Current.SttProvider;
            FileLogger.Info($"Sending to STT: provider={sttConfig.ProviderType}, model={sttConfig.Model}, audioSize={audioStream.Length}");
            var provider = _sttFactory.Create();

            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var transcribeTask = provider.TranscribeAsync(
                audioStream,
                _settings.Current.LanguageHint);

            var completed = await Task.WhenAny(transcribeTask, Task.Delay(-1, cts.Token));
            if (completed != transcribeTask)
            {
                throw new TimeoutException("Transcription timed out after 30 seconds");
            }
            result = await transcribeTask;

            FileLogger.Info($"Transcription OK: lang={result.DetectedLanguage}, text=\"{result.Text}\", duration={result.Duration.TotalSeconds:F1}s, noSpeech={result.NoSpeechProbability:F3}");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            FileLogger.Error("Transcription failed", ex);
            _notifications.ShowError($"Transcription failed: {ex.Message}");

            await _history.SaveAsync(new TranscriptRecord
            {
                Timestamp = DateTime.UtcNow,
                Text = $"[Transcription failed: {ex.Message}]",
                DetectedLanguage = "",
                DurationSeconds = 0,
                ProviderName = _settings.Current.SttProvider.ProviderType,
                InsertionSucceeded = false,
                TargetWindowName = targetWindow
            });

            SetState(AppState.Idle);
            return;
        }
        finally
        {
            audioStream.Dispose();
        }

        // Wait for all in-flight chunk transcriptions to complete
        Task[] pending;
        lock (_chunkTasks) { pending = _chunkTasks.ToArray(); }
        if (pending.Length > 0)
        {
            int remaining = pending.Count(t => !t.IsCompleted);
            FileLogger.Info($"Waiting for {remaining} of {pending.Length} chunk transcription(s)...");
            await Task.WhenAll(pending);
        }

        // Check if final segment is silence/noise (Whisper hallucinates Korean/Japanese on silence)
        var silenceThreshold = _settings.Current.SilenceThreshold;
        bool finalIsSilence = result.NoSpeechProbability > silenceThreshold;
        if (finalIsSilence)
            FileLogger.Info($"Final segment is silence: no_speech_prob={result.NoSpeechProbability:F3}");

        // Apply punctuation replacement to final segment (if not silence)
        if (!finalIsSilence)
        {
            var processedText = Stt.PunctuationReplacer.Apply(result.Text);
            if (processedText != result.Text)
            {
                FileLogger.Info($"Punctuation replaced: \"{result.Text}\" -> \"{processedText}\"");
                result = result with { Text = processedText };
            }
        }

        // Combine chunk results with the final segment
        string combinedText;
        lock (_chunkResults)
        {
            if (_chunkResults.Count > 0)
            {
                // Only include final segment if it's not silence
                if (!finalIsSilence)
                    _chunkResults.Add(result.Text);
                combinedText = string.Join(" ", _chunkResults.Where(t => !string.IsNullOrWhiteSpace(t)));
                FileLogger.Info($"Combined {_chunkResults.Count} chunks into final text ({combinedText.Length} chars)");
                _chunkResults.Clear();
            }
            else if (finalIsSilence)
            {
                // No chunks and final is silence — nothing to output
                FileLogger.Info("No speech detected (no chunks, final segment is silence).");
                _notifications.ShowInfo("No speech detected.");
                _selectedPromptIndex = -1;
                PromptChanged?.Invoke(this, null);
                SetState(AppState.Idle);
                return;
            }
            else
            {
                combinedText = result.Text;
            }
        }

        result = result with { Text = combinedText };

        // Add trailing period if enabled and text doesn't already end with punctuation
        if (_settings.Current.AddTrailingPeriod && !string.IsNullOrWhiteSpace(combinedText))
        {
            var trimmed = combinedText.TrimEnd();
            if (trimmed.Length > 0)
            {
                var lastChar = trimmed[^1];
                if (!char.IsPunctuation(lastChar))
                {
                    result = result with { Text = trimmed + "." };
                    FileLogger.Info("Added trailing period.");
                }
            }
        }

        if (string.IsNullOrWhiteSpace(result.Text))
        {
            FileLogger.Info("No speech detected in audio.");
            _notifications.ShowInfo("No speech detected.");
            SetState(AppState.Idle);
            return;
        }

        // Track usage: Whisper cost = $0.006/min
        var usage = _settings.Current.Usage;
        usage.TranscriptionCount++;
        usage.TotalAudioMinutes += result.Duration.TotalMinutes;
        usage.TotalWhisperCost += result.Duration.TotalMinutes * 0.006;

        // Apply GPT post-processing if a prompt was selected
        string usedPromptName = "";
        string originalText = "";
        if (_selectedPromptIndex >= 0)
        {
            SetState(AppState.PostProcessing);
            var enabledPrompts = _settings.Current.Prompts.Where(p => p.Enabled).ToList();
            if (_selectedPromptIndex < enabledPrompts.Count)
            {
                var prompt = enabledPrompts[_selectedPromptIndex];
                usedPromptName = prompt.Name;
                originalText = result.Text;
                FileLogger.Info($"Applying prompt \"{prompt.Name}\" to transcription...");
                _notifications.ShowInfo($"Processing: {prompt.Name}...");

                try
                {
                    var ppResult = await _postProcessor.ProcessAsync(
                        result.Text,
                        prompt.Prompt,
                        _settings.Current.LlmProvider.Model);

                    FileLogger.Info($"Post-process done: {ppResult.InputTokens} in, {ppResult.OutputTokens} out");
                    result = result with { Text = ppResult.Text };

                    // Track post-process usage (gpt-4o-mini: $0.15/1M in, $0.60/1M out)
                    usage.PostProcessTokensIn += ppResult.InputTokens;
                    usage.PostProcessTokensOut += ppResult.OutputTokens;
                    usage.TotalPostProcessCost += (ppResult.InputTokens * 0.15 + ppResult.OutputTokens * 0.60) / 1_000_000.0;
                }
                catch (Exception ex)
                {
                    FileLogger.Error("Post-processing failed", ex);
                    _notifications.ShowError($"Post-processing failed: {ex.Message}");
                    originalText = ""; // don't store original if processing failed
                }
            }
            _selectedPromptIndex = -1;
            PromptChanged?.Invoke(this, null);
        }

        // Save usage stats
        try { await _settings.SaveAsync(); }
        catch (Exception ex) { FileLogger.Error("Failed to save usage stats", ex); }

        // Refocus the window where recording started before inserting
        if (_recordingStartWindowHwnd != IntPtr.Zero)
        {
            FileLogger.Info($"Refocusing target window: 0x{_recordingStartWindowHwnd:X}");
            FocusWindow(_recordingStartWindowHwnd);
            await Task.Delay(30); // let the window activate
        }

        // Insert text
        var outputMode = Enum.Parse<OutputMode>(_settings.Current.OutputMode);
        bool insertionOk = true;
        try
        {
            FileLogger.Info($"Inserting text via {outputMode}: \"{result.Text}\"");
            await _output.InsertTextAsync(result.Text, outputMode);
            FileLogger.Info("Text insertion completed.");
        }
        catch (Exception ex)
        {
            insertionOk = false;
            FileLogger.Error("Text insertion failed", ex);
            _notifications.ShowError($"Insertion failed: {ex.Message}");
        }

        // Save to history
        var recordId = await _history.SaveAsync(new TranscriptRecord
        {
            Timestamp = DateTime.UtcNow,
            Text = result.Text,
            DetectedLanguage = result.DetectedLanguage,
            DurationSeconds = result.Duration.TotalSeconds,
            ProviderName = _settings.Current.SttProvider.ProviderType,
            InsertionSucceeded = insertionOk,
            TargetWindowName = targetWindow,
            PromptName = usedPromptName,
            OriginalText = originalText
        });
        FileLogger.Info($"Saved to history (id={recordId})");

        if (insertionOk)
            _notifications.ShowTranscriptionComplete(result.Text);

        SetState(AppState.Idle);
    }

    private void SetState(AppState newState)
    {
        FileLogger.Info($"State: {_state} -> {newState}");
        _state = newState;
        StateChanged?.Invoke(this, newState);
    }

    private static void FocusWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        try
        {
            uint currentThread = NativeMethods.GetCurrentThreadId();
            uint targetThread = (uint)NativeMethods.GetWindowThreadProcessId(hwnd, out _);

            if (currentThread != targetThread)
                NativeMethods.AttachThreadInput(currentThread, targetThread, true);

            NativeMethods.SetForegroundWindow(hwnd);

            if (currentThread != targetThread)
                NativeMethods.AttachThreadInput(currentThread, targetThread, false);

            FileLogger.Info($"Focused window: 0x{hwnd:X}");
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed to focus window", ex);
        }
    }

    private static string GetForegroundWindowName()
    {
        try
        {
            var hwnd = NativeMethods.GetForegroundWindow();
            return GetWindowName(hwnd);
        }
        catch
        {
            return "";
        }
    }

    private static string GetWindowName(IntPtr hwnd)
    {
        try
        {
            var sb = new StringBuilder(256);
            NativeMethods.GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }
        catch
        {
            return "";
        }
    }

    public void Dispose()
    {
        FileLogger.Info("Disposing orchestrator...");
        _hotkeys.HoldToTalkStarted -= OnHoldToTalkStarted;
        _hotkeys.HoldToTalkEnded -= OnHoldToTalkEnded;
        _hotkeys.ToggleRecordingPressed -= OnToggleRecordingPressed;
        _hotkeys.PasteLastTranscriptPressed -= OnPasteLastTranscriptPressed;
        _audio.SilenceDetected -= OnSilenceDetected;
        _hotkeys.PromptSelected -= OnPromptSelected;
        _hotkeys.PromptReleased -= OnPromptReleased;
        _hotkeys.Dispose();
        _audio.Dispose();
    }
}
