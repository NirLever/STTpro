using System.Runtime.InteropServices;
using System.Windows;
using STTpro.Core.Logging;
using STTpro.Interop;

namespace STTpro.Core.Output;

public class TextOutputService : ITextOutputService
{
    private readonly bool _restoreClipboard;

    public TextOutputService(bool restoreClipboard = true)
    {
        _restoreClipboard = restoreClipboard;
    }

    public async Task InsertTextAsync(string text, OutputMode mode)
    {
        if (string.IsNullOrEmpty(text))
            return;

        switch (mode)
        {
            case OutputMode.DirectTyping:
                await Task.Run(() => SendUnicodeText(text));
                break;

            case OutputMode.ClipboardPaste:
                await ClipboardPasteAsync(text);
                break;

            case OutputMode.CopyOnly:
                await SetClipboardTextAsync(text);
                break;

            case OutputMode.SaveOnly:
                break;
        }
    }

    private static void SendUnicodeText(string text)
    {
        var inputs = new List<NativeMethods.INPUT>();

        foreach (char c in text)
        {
            inputs.Add(new NativeMethods.INPUT
            {
                type = NativeMethods.INPUT_KEYBOARD,
                u = new NativeMethods.INPUTUNION
                {
                    ki = new NativeMethods.KEYBDINPUT
                    {
                        wVk = 0,
                        wScan = c,
                        dwFlags = NativeMethods.KEYEVENTF_UNICODE,
                        time = 0,
                        dwExtraInfo = IntPtr.Zero
                    }
                }
            });

            inputs.Add(new NativeMethods.INPUT
            {
                type = NativeMethods.INPUT_KEYBOARD,
                u = new NativeMethods.INPUTUNION
                {
                    ki = new NativeMethods.KEYBDINPUT
                    {
                        wVk = 0,
                        wScan = c,
                        dwFlags = NativeMethods.KEYEVENTF_UNICODE | NativeMethods.KEYEVENTF_KEYUP,
                        time = 0,
                        dwExtraInfo = IntPtr.Zero
                    }
                }
            });
        }

        var inputArray = inputs.ToArray();
        NativeMethods.SendInput((uint)inputArray.Length, inputArray, Marshal.SizeOf<NativeMethods.INPUT>());
    }

    private async Task ClipboardPasteAsync(string text)
    {
        string? previousText = null;

        // Set text to clipboard on the WPF dispatcher thread
        await Application.Current.Dispatcher.InvokeAsync(() =>
        {
            // Save current clipboard text (simple - just text, not all formats)
            if (_restoreClipboard)
            {
                try
                {
                    if (Clipboard.ContainsText())
                        previousText = Clipboard.GetText();
                }
                catch { }
            }

            // Set transcript to clipboard with retries
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    Clipboard.SetText(text);
                    FileLogger.Info("Clipboard text set successfully.");
                    return;
                }
                catch (COMException)
                {
                    Thread.Sleep(50);
                }
            }
            FileLogger.Error("Failed to set clipboard text after 5 retries.");
        });

        // Send Ctrl+V
        FileLogger.Info("Sending Ctrl+V...");
        SendCtrlV();

        // Brief wait for the target app to process the paste before restoring clipboard
        await Task.Delay(150);

        // Restore clipboard
        if (_restoreClipboard && previousText != null)
        {
            await Application.Current.Dispatcher.InvokeAsync(() =>
            {
                try { Clipboard.SetText(previousText); }
                catch { }
            });
        }
    }

    private static async Task SetClipboardTextAsync(string text)
    {
        await Application.Current.Dispatcher.InvokeAsync(() =>
        {
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    Clipboard.SetText(text);
                    return;
                }
                catch (COMException)
                {
                    Thread.Sleep(50);
                }
            }
        });
    }

    private static void SendCtrlV()
    {
        var inputs = new NativeMethods.INPUT[]
        {
            // Ctrl down
            new()
            {
                type = NativeMethods.INPUT_KEYBOARD,
                u = new NativeMethods.INPUTUNION
                {
                    ki = new NativeMethods.KEYBDINPUT { wVk = NativeMethods.VK_CONTROL }
                }
            },
            // V down
            new()
            {
                type = NativeMethods.INPUT_KEYBOARD,
                u = new NativeMethods.INPUTUNION
                {
                    ki = new NativeMethods.KEYBDINPUT { wVk = NativeMethods.VK_V }
                }
            },
            // V up
            new()
            {
                type = NativeMethods.INPUT_KEYBOARD,
                u = new NativeMethods.INPUTUNION
                {
                    ki = new NativeMethods.KEYBDINPUT { wVk = NativeMethods.VK_V, dwFlags = NativeMethods.KEYEVENTF_KEYUP }
                }
            },
            // Ctrl up
            new()
            {
                type = NativeMethods.INPUT_KEYBOARD,
                u = new NativeMethods.INPUTUNION
                {
                    ki = new NativeMethods.KEYBDINPUT { wVk = NativeMethods.VK_CONTROL, dwFlags = NativeMethods.KEYEVENTF_KEYUP }
                }
            }
        };

        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.INPUT>());
        FileLogger.Info($"SendInput Ctrl+V: {sent} events sent");
    }
}
