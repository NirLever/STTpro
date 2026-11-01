using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using STTpro.Core.Logging;
using STTpro.Interop;
// WinForms is also referenced, so DataObject is ambiguous without this.
using WpfDataObject = System.Windows.DataObject;

namespace STTpro.Core.Output;

public class TextOutputService : ITextOutputService
{
    /// <summary>
    /// How long the target app gets to read the clipboard after Ctrl+V before the
    /// user's own clipboard is put back. 150 ms was too short for busy apps
    /// (Electron, browsers, Fusion 360): they read the clipboard after it had
    /// already been restored and pasted the old content instead of the transcript.
    /// </summary>
    private const int PasteSettleMs = 350;

    /// <summary>
    /// Registered clipboard format telling Windows clipboard history (Win+V), cloud
    /// clipboard and clipboard managers to ignore an entry. Put on the transient
    /// transcript and on the restored copy, so dictating leaves history untouched.
    /// </summary>
    internal const string ExcludeFromMonitors = "ExcludeClipboardContentFromMonitorProcessing";

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

    /// <summary>
    /// Pastes the transcript through the clipboard without losing what the user had
    /// copied. Rules:
    ///  * Everything on the clipboard is saved - text, rich text, HTML, images,
    ///    copied files - not just plain text.
    ///  * If the clipboard cannot be read, it is never overwritten: the transcript
    ///    is typed directly instead.
    ///  * If the user copies something new while the paste is in flight, their new
    ///    copy wins and nothing is restored over it.
    /// </summary>
    private async Task ClipboardPasteAsync(string text)
    {
        if (!_restoreClipboard)
        {
            var placed = await Application.Current.Dispatcher.InvokeAsync(
                () => TrySetClipboard(() => TranscriptData(text, transient: false)));
            if (!placed)
            {
                FileLogger.Error("Clipboard unavailable - typing the transcript directly instead.");
                await Task.Run(() => SendUnicodeText(text));
                return;
            }
            FileLogger.Info("Sending Ctrl+V...");
            SendCtrlV();
            return;
        }

        ClipboardSnapshot? saved = null;
        bool placedTranscript = false;
        uint seqBeforeSet = 0, seqAfterSet = 0;

        await Application.Current.Dispatcher.InvokeAsync(() =>
        {
            saved = ClipboardSnapshot.Capture();
            if (saved == null)
                return; // could not read it, so we must not overwrite it

            seqBeforeSet = NativeMethods.GetClipboardSequenceNumber();
            placedTranscript = TrySetClipboard(() => TranscriptData(text, transient: true));
            if (placedTranscript)
                seqAfterSet = NativeMethods.GetClipboardSequenceNumber();
        });

        if (saved == null)
        {
            FileLogger.Error("Could not read the clipboard to save it - typing the transcript directly so the user's copy is not lost.");
            await Task.Run(() => SendUnicodeText(text));
            return;
        }

        var snapshot = saved;
        FileLogger.Info($"Clipboard saved ({snapshot.Describe()}).");

        if (!placedTranscript)
        {
            FileLogger.Error("Could not place the transcript on the clipboard - typing it directly.");
            // A failed set can leave the clipboard emptied; put the user's copy back if anything moved.
            await Application.Current.Dispatcher.InvokeAsync(() =>
            {
                if (NativeMethods.GetClipboardSequenceNumber() != seqBeforeSet)
                    snapshot.Restore();
            });
            await Task.Run(() => SendUnicodeText(text));
            return;
        }

        FileLogger.Info("Sending Ctrl+V...");
        SendCtrlV();

        await Task.Delay(PasteSettleMs);

        await Application.Current.Dispatcher.InvokeAsync(() =>
        {
            if (NativeMethods.GetClipboardSequenceNumber() != seqAfterSet)
            {
                FileLogger.Info("Clipboard changed during the paste (something new was copied) - leaving it alone.");
                return;
            }
            if (snapshot.Restore())
                FileLogger.Info("Clipboard restored.");
            else
                FileLogger.Error("Failed to restore the previous clipboard contents.");
        });
    }

    private static WpfDataObject TranscriptData(string text, bool transient)
    {
        var data = new WpfDataObject();
        data.SetText(text);
        if (transient)
            data.SetData(ExcludeFromMonitors, new MemoryStream(new byte[4]), false);
        return data;
    }

    /// <summary>Sets the clipboard, retrying while another app has it open.</summary>
    private static bool TrySetClipboard(Func<WpfDataObject> build)
    {
        for (int attempt = 0; attempt < 8; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(build(), true);
                return true;
            }
            catch (ExternalException)
            {
                Thread.Sleep(25 * (attempt + 1));
            }
        }
        return false;
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

    /// <summary>
    /// A detached copy of everything on the clipboard - text, rich text, HTML,
    /// images and copied files - that survives the clipboard being overwritten.
    /// </summary>
    private sealed class ClipboardSnapshot
    {
        private sealed record Bytes(byte[] Data);

        // What people actually copy. If a full restore is refused because some
        // app-private format will not re-serialise, these are restored instead.
        private static readonly HashSet<string> CoreFormats = new(StringComparer.OrdinalIgnoreCase)
        {
            "UnicodeText", "Text", "OEMText", "Locale", "HTML Format", "Rich Text Format",
            "Bitmap", "DeviceIndependentBitmap", "Format17", "PNG",
            "FileDrop", "FileNameW", "FileName", "Shell IDList Array", "Preferred DropEffect",
        };

        private List<(string Format, object Data)> _items;

        private ClipboardSnapshot(List<(string Format, object Data)> items) => _items = items;

        public string Describe() => _items.Count == 0
            ? "clipboard was empty"
            : $"{_items.Count} format(s): {string.Join(", ", _items.Select(i => i.Format).Take(6))}";

        /// <summary>
        /// Returns null if the clipboard could not be read reliably. An empty
        /// snapshot means the clipboard really was empty.
        /// </summary>
        public static ClipboardSnapshot? Capture()
        {
            for (int attempt = 0; attempt < 8; attempt++)
            {
                try
                {
                    var items = new List<(string Format, object Data)>();
                    var source = Clipboard.GetDataObject();
                    var formats = source?.GetFormats(false) ?? Array.Empty<string>();
                    foreach (var format in formats)
                    {
                        try
                        {
                            var copy = Detach(source!.GetData(format, false));
                            if (copy != null)
                                items.Add((format, copy));
                        }
                        catch (Exception)
                        {
                            // This one format cannot be read right now - skip it.
                        }
                    }

                    // Formats were present but none could be read: that is a failed
                    // read, not an empty clipboard. Treating it as empty would wipe it.
                    if (formats.Length > 0 && items.Count == 0)
                        throw new ExternalException("Clipboard formats present but unreadable");

                    return new ClipboardSnapshot(items);
                }
                catch (ExternalException)
                {
                    Thread.Sleep(25 * (attempt + 1));
                }
            }
            return null;
        }

        private static object? Detach(object? value) => value switch
        {
            null => null,
            string s => s,
            string[] list => (string[])list.Clone(),
            Stream stream => new Bytes(ReadAll(stream)),
            BitmapSource image => FrozenCopy(image),
            _ => null, // live COM objects etc. cannot outlive the clipboard changing
        };

        private static BitmapSource FrozenCopy(BitmapSource image)
        {
            var copy = new WriteableBitmap(image);
            copy.Freeze();
            return copy;
        }

        private static byte[] ReadAll(Stream stream)
        {
            if (stream is MemoryStream ms)
                return ms.ToArray();
            using var buffer = new MemoryStream();
            if (stream.CanSeek)
                stream.Position = 0;
            stream.CopyTo(buffer);
            return buffer.ToArray();
        }

        public bool Restore()
        {
            Exception? last = null;
            for (int attempt = 0; attempt < 8; attempt++)
            {
                if (attempt == 4)
                {
                    var core = _items.Where(i => CoreFormats.Contains(i.Format)).ToList();
                    if (core.Count > 0)
                        _items = core;
                }
                try
                {
                    if (_items.Count == 0)
                    {
                        Clipboard.Clear();
                        return true;
                    }

                    var data = new WpfDataObject();
                    foreach (var (format, value) in _items)
                        data.SetData(format, value is Bytes b ? new MemoryStream(b.Data) : value, false);
                    data.SetData(ExcludeFromMonitors, new MemoryStream(new byte[4]), false);
                    Clipboard.SetDataObject(data, true);
                    return true;
                }
                catch (Exception ex)
                {
                    last = ex;
                    Thread.Sleep(25 * (attempt + 1));
                }
            }
            if (last != null)
                FileLogger.Error("Clipboard restore gave up", last);
            return false;
        }
    }
}
