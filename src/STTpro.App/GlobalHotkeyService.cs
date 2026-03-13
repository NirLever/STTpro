using System.Windows.Interop;
using System.Windows.Threading;
using STTpro.Core.Logging;
using STTpro.Interop;

namespace STTpro.Core.Hotkeys;

public class GlobalHotkeyService : IGlobalHotkeyService
{
    private const int HOTKEY_TOGGLE = 1;
    private const int HOTKEY_PASTE = 2;
    private const int HOTKEY_PROMPT_BASE = 100; // 100..108 for Ctrl+Shift+1..Ctrl+Shift+9

    private IntPtr _hwnd;
    private HwndSource? _hwndSource;
    private readonly LowLevelKeyboardHook _keyboardHook;
    private int _registeredPromptCount;
    private bool _paused;

    // Store registration info for pause/resume
    private uint _holdMods, _holdKey;
    private uint _toggleMods, _toggleKey;
    private uint _pasteMods, _pasteKey;

    // Hold mode: poll for key release
    private DispatcherTimer? _holdPollTimer;
    private int _heldPromptIndex = -1;
    private uint _heldPromptVk;

    public event EventHandler? ToggleRecordingPressed;
    public event EventHandler? PasteLastTranscriptPressed;
    public event EventHandler? HoldToTalkStarted;
    public event EventHandler? HoldToTalkEnded;
    public event EventHandler<int>? PromptSelected;
    /// <summary>Fired when a prompt hotkey is released (hold mode only).</summary>
    public event EventHandler<int>? PromptReleased;

    public GlobalHotkeyService()
    {
        _keyboardHook = new LowLevelKeyboardHook();
        _keyboardHook.KeyDown += (_, _) =>
        {
            if (!_paused) HoldToTalkStarted?.Invoke(this, EventArgs.Empty);
        };
        _keyboardHook.KeyUp += (_, _) =>
        {
            if (!_paused) HoldToTalkEnded?.Invoke(this, EventArgs.Empty);
        };
    }

    /// <summary>
    /// Must be called from the WPF dispatcher thread after the application starts.
    /// Creates a hidden message-only window for receiving WM_HOTKEY messages.
    /// </summary>
    public void Initialize()
    {
        var parameters = new HwndSourceParameters("STTproHotkeyWindow")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0
        };
        _hwndSource = new HwndSource(parameters);
        _hwnd = _hwndSource.Handle;
        _hwndSource.AddHook(WndProc);
    }

    public void RegisterToggleRecording(uint modifiers, uint keyCode)
    {
        _toggleMods = modifiers;
        _toggleKey = keyCode;
        var ok = NativeMethods.RegisterHotKey(_hwnd, HOTKEY_TOGGLE, modifiers | NativeMethods.MOD_NOREPEAT, keyCode);
        FileLogger.Info($"RegisterHotKey toggle: mods=0x{modifiers:X}, vk=0x{keyCode:X} -> {ok}");
    }

    public void RegisterPasteLastTranscript(uint modifiers, uint keyCode)
    {
        _pasteMods = modifiers;
        _pasteKey = keyCode;
        var ok = NativeMethods.RegisterHotKey(_hwnd, HOTKEY_PASTE, modifiers | NativeMethods.MOD_NOREPEAT, keyCode);
        FileLogger.Info($"RegisterHotKey paste: mods=0x{modifiers:X}, vk=0x{keyCode:X} -> {ok}");
    }

    public void StartHoldToTalkListening(uint modifiers, uint keyCode)
    {
        _holdMods = modifiers;
        _holdKey = keyCode;
        _keyboardHook.Install(modifiers, keyCode);
    }

    private List<(uint mods, uint vk)> _promptBindings = new();

    public void RegisterPromptHotkeys(IReadOnlyList<Core.Settings.HotkeyBinding?> bindings)
    {
        // Unregister previous prompt hotkeys
        for (int i = 0; i < _registeredPromptCount; i++)
            NativeMethods.UnregisterHotKey(_hwnd, HOTKEY_PROMPT_BASE + i);

        _promptBindings.Clear();
        _registeredPromptCount = Math.Min(bindings.Count, 9);
        for (int i = 0; i < _registeredPromptCount; i++)
        {
            var binding = bindings[i];
            uint mods, vk;
            if (binding != null && binding.KeyCode != 0)
            {
                mods = binding.Modifiers;
                vk = binding.KeyCode;
            }
            else
            {
                // Default: Ctrl+Shift+{i+1}
                mods = 0x0002 | 0x0004; // MOD_CONTROL | MOD_SHIFT
                vk = (uint)(0x31 + i);  // VK_1 = 0x31
            }
            _promptBindings.Add((mods, vk));
            var ok = NativeMethods.RegisterHotKey(_hwnd, HOTKEY_PROMPT_BASE + i,
                mods | NativeMethods.MOD_NOREPEAT, vk);
            FileLogger.Info($"RegisterHotKey prompt[{i}]: mods=0x{mods:X}, vk=0x{vk:X} -> {ok}");
        }
    }

    /// <summary>
    /// Temporarily pause all hotkey processing (used during hotkey capture in settings).
    /// </summary>
    public void Pause()
    {
        _paused = true;
        // Unregister RegisterHotKey-based hotkeys so they don't fire
        NativeMethods.UnregisterHotKey(_hwnd, HOTKEY_TOGGLE);
        NativeMethods.UnregisterHotKey(_hwnd, HOTKEY_PASTE);
        for (int i = 0; i < _registeredPromptCount; i++)
            NativeMethods.UnregisterHotKey(_hwnd, HOTKEY_PROMPT_BASE + i);
        FileLogger.Info("Hotkeys paused for capture");
    }

    /// <summary>
    /// Resume hotkey processing after capture.
    /// </summary>
    public void Resume()
    {
        _paused = false;
        // Re-register all hotkeys
        if (_toggleKey != 0)
            NativeMethods.RegisterHotKey(_hwnd, HOTKEY_TOGGLE, _toggleMods | NativeMethods.MOD_NOREPEAT, _toggleKey);
        if (_pasteKey != 0)
            NativeMethods.RegisterHotKey(_hwnd, HOTKEY_PASTE, _pasteMods | NativeMethods.MOD_NOREPEAT, _pasteKey);
        for (int i = 0; i < _registeredPromptCount && i < _promptBindings.Count; i++)
        {
            var (mods, vk) = _promptBindings[i];
            NativeMethods.RegisterHotKey(_hwnd, HOTKEY_PROMPT_BASE + i, mods | NativeMethods.MOD_NOREPEAT, vk);
        }
        FileLogger.Info("Hotkeys resumed after capture");
    }

    public void UnregisterAll()
    {
        NativeMethods.UnregisterHotKey(_hwnd, HOTKEY_TOGGLE);
        NativeMethods.UnregisterHotKey(_hwnd, HOTKEY_PASTE);
        for (int i = 0; i < _registeredPromptCount; i++)
            NativeMethods.UnregisterHotKey(_hwnd, HOTKEY_PROMPT_BASE + i);
        _registeredPromptCount = 0;
        _keyboardHook.Uninstall();
    }

    /// <summary>
    /// Set to true to enable hold-to-record for prompt hotkeys.
    /// When enabled, PromptSelected fires on key down and PromptReleased fires when key is released.
    /// </summary>
    public bool PromptHoldMode { get; set; }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_HOTKEY && !_paused)
        {
            int id = wParam.ToInt32();
            switch (id)
            {
                case HOTKEY_TOGGLE:
                    ToggleRecordingPressed?.Invoke(this, EventArgs.Empty);
                    handled = true;
                    break;
                case HOTKEY_PASTE:
                    PasteLastTranscriptPressed?.Invoke(this, EventArgs.Empty);
                    handled = true;
                    break;
                default:
                    if (id >= HOTKEY_PROMPT_BASE && id < HOTKEY_PROMPT_BASE + _registeredPromptCount)
                    {
                        int promptIndex = id - HOTKEY_PROMPT_BASE;
                        PromptSelected?.Invoke(this, promptIndex);
                        handled = true;

                        // In hold mode, start polling for key release
                        if (PromptHoldMode && promptIndex < _promptBindings.Count)
                            StartHoldPoll(promptIndex, _promptBindings[promptIndex].vk);
                    }
                    break;
            }
        }
        return IntPtr.Zero;
    }

    private void StartHoldPoll(int promptIndex, uint vk)
    {
        _heldPromptIndex = promptIndex;
        _heldPromptVk = vk;
        if (_holdPollTimer == null)
        {
            _holdPollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
            _holdPollTimer.Tick += HoldPollTimer_Tick;
        }
        _holdPollTimer.Start();
    }

    private void HoldPollTimer_Tick(object? sender, EventArgs e)
    {
        // Check if the number key is still held
        bool keyStillHeld = (NativeMethods.GetAsyncKeyState((int)_heldPromptVk) & 0x8000) != 0;
        if (!keyStillHeld)
        {
            _holdPollTimer?.Stop();
            FileLogger.Info($"Prompt hold released: [{_heldPromptIndex}]");
            PromptReleased?.Invoke(this, _heldPromptIndex);
            _heldPromptIndex = -1;
        }
    }

    public void Dispose()
    {
        UnregisterAll();
        _keyboardHook.Dispose();
        _hwndSource?.Dispose();
    }
}
