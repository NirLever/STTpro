using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;
using STTpro.Core.Logging;

namespace STTpro.App.Theme;

/// <summary>
/// Centralised light/dark theming. Follows the Windows system setting, swaps the
/// active palette ResourceDictionary at runtime (so DynamicResource-bound UI
/// re-themes live), and paints native window title bars to match.
/// </summary>
public static class ThemeManager
{
    private const int DwmwaUseImmersiveDarkMode = 20;         // Win10 2004+ / Win11
    private const int DwmwaUseImmersiveDarkModeOld = 19;      // Win10 1809–1909

    private static readonly HashSet<Window> Windows = new();
    private static bool _isDark;
    private static string _mode = "system"; // "system" | "light" | "dark"

    /// <summary>True when the dark palette is currently active.</summary>
    public static bool IsDark => _isDark;

    /// <summary>Apply the saved appearance mode. Call once at startup.</summary>
    public static void Initialize(string mode)
    {
        _mode = Normalize(mode);
        Apply(ShouldUseDark());
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
    }

    /// <summary>Change the appearance mode at runtime (from the Settings combo).</summary>
    public static void SetMode(string mode)
    {
        _mode = Normalize(mode);
        var dark = ShouldUseDark();
        if (dark != _isDark)
            Apply(dark);
    }

    private static string Normalize(string? mode) =>
        mode is "light" or "dark" ? mode : "system";

    /// <summary>Register a window so it gets a matching title bar now and on theme changes.</summary>
    public static void RegisterWindow(Window window)
    {
        if (window == null) return;
        Windows.Add(window);
        window.Closed += (_, _) => Windows.Remove(window);

        if (window.IsLoaded || new WindowInteropHelper(window).Handle != IntPtr.Zero)
            ApplyToWindow(window);
        else
            window.SourceInitialized += (_, _) => ApplyToWindow(window);
    }

    private static void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.VisualStyle)
        {
            var dark = ShouldUseDark();
            if (dark != _isDark)
                Application.Current?.Dispatcher.Invoke(() => Apply(dark));
        }
    }

    private static void Apply(bool dark)
    {
        _isDark = dark;
        var app = Application.Current;
        if (app == null) return;

        var uri = new Uri($"Themes/Palette.{(dark ? "Dark" : "Light")}.xaml", UriKind.Relative);
        var palette = new ResourceDictionary { Source = uri };

        // Slot 0 is the palette (see App.xaml); replace it in place.
        var merged = app.Resources.MergedDictionaries;
        if (merged.Count > 0)
            merged[0] = palette;
        else
            merged.Add(palette);

        foreach (var w in Windows)
            ApplyToWindow(w);
    }

    private static bool ShouldUseDark()
    {
        if (_mode == "light") return false;
        if (_mode == "dark") return true;
        // "system": read the Windows apps theme.
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            // AppsUseLightTheme: 0 = dark, 1 = light. Missing => assume light.
            if (key?.GetValue("AppsUseLightTheme") is int v)
                return v == 0;
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed reading system theme", ex);
        }
        return false;
    }

    private static void ApplyToWindow(Window window)
    {
        try
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero) return;

            int useDark = _isDark ? 1 : 0;
            if (DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref useDark, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkModeOld, ref useDark, sizeof(int));
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed applying title bar theme", ex);
        }
    }

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
