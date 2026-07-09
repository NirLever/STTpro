using System.Diagnostics;
using System.Runtime.InteropServices;
using STTpro.Interop;

namespace STTpro.Core.Hotkeys;

/// <summary>
/// Low-level keyboard hook for detecting key-down and key-up events.
/// Required for hold-to-talk since RegisterHotKey doesn't fire on key-up.
/// Must be created and used on a thread with a message pump (WPF dispatcher).
/// </summary>
public class LowLevelKeyboardHook : IDisposable
{
    private IntPtr _hookId = IntPtr.Zero;
    // Store delegate to prevent GC collection
    private readonly NativeMethods.LowLevelKeyboardProc _hookProc;

    private uint _targetKeyCode;
    private uint _targetModifiers;
    private bool _isKeyDown;

    public event EventHandler? KeyDown;
    public event EventHandler? KeyUp;

    public LowLevelKeyboardHook()
    {
        _hookProc = HookCallback;
    }

    public void Install(uint modifiers, uint keyCode)
    {
        _targetModifiers = modifiers;
        _targetKeyCode = keyCode;

        if (_hookId != IntPtr.Zero)
            Uninstall();

        using var process = Process.GetCurrentProcess();
        using var module = process.MainModule!;
        _hookId = NativeMethods.SetWindowsHookEx(
            NativeMethods.WH_KEYBOARD_LL,
            _hookProc,
            NativeMethods.GetModuleHandle(module.ModuleName),
            0);
    }

    public void Uninstall()
    {
        if (_hookId != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
            _isKeyDown = false;
        }
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= NativeMethods.HC_ACTION)
        {
            var hookStruct = Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
            int msg = wParam.ToInt32();

            if (hookStruct.vkCode == _targetKeyCode && AreModifiersPressed())
            {
                if ((msg == NativeMethods.WM_KEYDOWN || msg == NativeMethods.WM_SYSKEYDOWN) && !_isKeyDown)
                {
                    _isKeyDown = true;
                    KeyDown?.Invoke(this, EventArgs.Empty);
                }
                else if ((msg == NativeMethods.WM_KEYUP || msg == NativeMethods.WM_SYSKEYUP) && _isKeyDown)
                {
                    _isKeyDown = false;
                    KeyUp?.Invoke(this, EventArgs.Empty);
                }
            }
            // If the target key goes up without modifiers, still release
            else if (hookStruct.vkCode == _targetKeyCode &&
                     (msg == NativeMethods.WM_KEYUP || msg == NativeMethods.WM_SYSKEYUP) && _isKeyDown)
            {
                _isKeyDown = false;
                KeyUp?.Invoke(this, EventArgs.Empty);
            }
            // If a modifier key is released while we think the combo is held, fire release
            // (covers the case where the target key-up was lost due to focus change etc.)
            else if (_isKeyDown && IsModifierKey(hookStruct.vkCode) &&
                     (msg == NativeMethods.WM_KEYUP || msg == NativeMethods.WM_SYSKEYUP) &&
                     !IsTargetKeyPhysicallyDown())
            {
                _isKeyDown = false;
                KeyUp?.Invoke(this, EventArgs.Empty);
            }
        }

        return NativeMethods.CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    private static bool IsModifierKey(uint vkCode) =>
        vkCode is 0x10 or 0x11 or 0x12   // VK_SHIFT, VK_CONTROL, VK_MENU
              or 0xA0 or 0xA1             // VK_LSHIFT, VK_RSHIFT
              or 0xA2 or 0xA3             // VK_LCONTROL, VK_RCONTROL
              or 0xA4 or 0xA5;            // VK_LMENU, VK_RMENU

    private bool IsTargetKeyPhysicallyDown() =>
        (GetAsyncKeyState((int)_targetKeyCode) & 0x8000) != 0;

    private bool AreModifiersPressed()
    {
        bool ctrlPressed = (GetAsyncKeyState(0x11) & 0x8000) != 0;
        bool shiftPressed = (GetAsyncKeyState(0x10) & 0x8000) != 0;
        bool altPressed = (GetAsyncKeyState(0x12) & 0x8000) != 0;

        bool needCtrl = (_targetModifiers & NativeMethods.MOD_CONTROL) != 0;
        bool needShift = (_targetModifiers & NativeMethods.MOD_SHIFT) != 0;
        bool needAlt = (_targetModifiers & NativeMethods.MOD_ALT) != 0;

        // Exact match: required modifiers must be pressed, extra modifiers must NOT be pressed
        return ctrlPressed == needCtrl && shiftPressed == needShift && altPressed == needAlt;
    }

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    public void Dispose()
    {
        Uninstall();
    }
}
