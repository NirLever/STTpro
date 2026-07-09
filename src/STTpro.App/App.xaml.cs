using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Extensions.DependencyInjection;
using STTpro.App.Theme;
using STTpro.App.Views;
using STTpro.Core;
using STTpro.Core.Audio;
using STTpro.Core.History;
using STTpro.Core.Hotkeys;
using STTpro.Core.Logging;
using STTpro.Core.Notifications;
using STTpro.Core.Output;
using STTpro.Core.Security;
using STTpro.Core.Settings;
using STTpro.Core.Stt;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace STTpro.App;

public partial class App : Application
{
    private static Mutex? _singleInstanceMutex;
    private Forms.NotifyIcon? _trayIcon;
    private ServiceProvider? _serviceProvider;
    private AppOrchestrator? _orchestrator;
    private RecordingIndicator? _recordingIndicator;
    private RecordingBorderOverlay? _borderOverlay;
    private PromptToast? _promptToast;
    private SettingsWindow? _settingsWindow;
    private INotificationService? _notifications;

    private static bool _isRestarting;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        FileLogger.Info("=== STTpro starting ===");

        // Apply the light/dark palette from the Windows system setting before any window loads.
        ThemeManager.Initialize();

        // Global exception handlers to prevent silent crashes
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnAppDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;

        // Single-instance enforcement
        bool mutexAcquired = false;
        try
        {
            _singleInstanceMutex = new Mutex(false, "Global\\STTpro_SingleInstance");
            FileLogger.Info("Mutex created, attempting to acquire...");
            mutexAcquired = _singleInstanceMutex.WaitOne(0, false);
            FileLogger.Info($"Mutex acquire result: {mutexAcquired}");
        }
        catch (AbandonedMutexException)
        {
            FileLogger.Info("Acquired abandoned mutex from crashed instance");
            mutexAcquired = true;
        }
        catch (Exception ex)
        {
            FileLogger.Error("Mutex error", ex);
            mutexAcquired = true; // proceed anyway on error
        }

        if (!mutexAcquired)
        {
            FileLogger.Info("Another instance is running, shutting down");
            MessageBox.Show("STTpro is already running.", "STTpro", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        // Build DI container
        var services = new ServiceCollection();
        ConfigureServices(services);
        _serviceProvider = services.BuildServiceProvider();

        // Create tray icon using WinForms NotifyIcon (most reliable on Windows)
        SetupTrayIcon();

        // Wire tray icon to notification service for balloon tips
        _notifications = _serviceProvider.GetRequiredService<INotificationService>();
        if (_notifications is TrayNotificationService tns)
            tns.SetTrayIcon(_trayIcon!);

        try
        {
            // Create recording indicator and border overlay
            _recordingIndicator = new RecordingIndicator();
            _recordingIndicator.StopRequested += (_, _) => _orchestrator?.StopRecordingFromUI();
            _recordingIndicator.CancelRequested += (_, _) => _orchestrator?.CancelRecordingFromUI();
            _borderOverlay = new RecordingBorderOverlay();
            _promptToast = new PromptToast();
            FileLogger.Info("UI overlays created");

            // Initialize orchestrator
            _orchestrator = _serviceProvider.GetRequiredService<AppOrchestrator>();
            _orchestrator.StateChanged += OnStateChanged;
            _orchestrator.PromptChanged += OnPromptChanged;

            // Initialize hotkey service (must be on dispatcher thread)
            var hotkeyService = _serviceProvider.GetRequiredService<IGlobalHotkeyService>();
            if (hotkeyService is GlobalHotkeyService ghs)
            {
                ghs.Initialize();
                var settings = _serviceProvider.GetRequiredService<ISettingsService>();
                ghs.PromptHoldMode = settings.Current.PromptHotkeyMode == "hold";
            }

            await _orchestrator.InitializeAsync();
        }
        catch (Exception ex)
        {
            FileLogger.Error("Initialization failed", ex);
            MessageBox.Show($"Initialization error: {ex.Message}", "STTpro", MessageBoxButton.OK, MessageBoxImage.Error);
        }

        // Auto-show settings on first launch if no API key configured for STT provider
        var credStore = _serviceProvider.GetRequiredService<DpapiCredentialStore>();
        var settingsForCheck = _serviceProvider.GetRequiredService<ISettingsService>();
        var sttSlot = settingsForCheck.Current.SttProvider.ApiKeySlot;
        if (ApiProviders.RequiresApiKey(settingsForCheck.Current.SttProvider.ProviderType) && !credStore.HasApiKey(sttSlot))
        {
            ShowSettings();
        }
    }

    private static void ConfigureServices(ServiceCollection services)
    {
        // Settings & Security
        services.AddSingleton<ISettingsService, JsonSettingsService>();
        services.AddSingleton<DpapiCredentialStore>();

        // Audio
        services.AddSingleton<IAudioCaptureService, NAudioCaptureService>();

        // Hotkeys
        services.AddSingleton<IGlobalHotkeyService, GlobalHotkeyService>();

        // STT & Post-processing
        services.AddSingleton<SttProviderFactory>();
        services.AddSingleton<GptPostProcessor>();

        // Output
        services.AddSingleton<ITextOutputService>(sp =>
        {
            var settings = sp.GetRequiredService<ISettingsService>();
            return new TextOutputService(settings.Current.RestoreClipboard);
        });

        // History
        services.AddSingleton<ITranscriptRepository, SqliteTranscriptRepository>();

        // Notifications
        services.AddSingleton<INotificationService, TrayNotificationService>();

        // Orchestrator
        services.AddSingleton<AppOrchestrator>();
    }

    private void SetupTrayIcon()
    {
        _trayIcon = new Forms.NotifyIcon
        {
            Text = "STTpro - Speech to Text",
            Icon = CreateTrayIcon(),
            Visible = true,
            ContextMenuStrip = CreateContextMenu()
        };

        // Left-click opens/restores settings; right-click shows context menu naturally
        _trayIcon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
                Dispatcher.Invoke(ShowSettings);
        };
    }

    private static Drawing.Icon CreateTrayIcon()
    {
        using var bmp = new Drawing.Bitmap(32, 32);
        using var g = Drawing.Graphics.FromImage(bmp);
        g.Clear(Drawing.Color.Transparent);
        g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;

        // Mic body (rounded rectangle approximated by ellipse)
        using var brush = new Drawing.SolidBrush(Drawing.Color.FromArgb(80, 160, 255));
        using var pen = new Drawing.Pen(Drawing.Color.FromArgb(80, 160, 255), 2.5f);
        g.FillEllipse(brush, 10, 2, 12, 18);

        // Mic arc
        g.DrawArc(pen, 6, 8, 20, 18, 0, 180);

        // Mic stand
        g.DrawLine(pen, 16, 26, 16, 30);
        g.DrawLine(pen, 10, 30, 22, 30);

        var hIcon = bmp.GetHicon();
        return Drawing.Icon.FromHandle(hIcon);
    }

    private Forms.ContextMenuStrip CreateContextMenu()
    {
        var menu = new Forms.ContextMenuStrip();

        var settingsItem = new Forms.ToolStripMenuItem("Settings");
        settingsItem.Click += (_, _) => Dispatcher.Invoke(ShowSettings);
        menu.Items.Add(settingsItem);

        var historyItem = new Forms.ToolStripMenuItem("History");
        historyItem.Click += (_, _) => Dispatcher.Invoke(ShowHistory);
        menu.Items.Add(historyItem);

        menu.Items.Add(new Forms.ToolStripSeparator());

        var exitItem = new Forms.ToolStripMenuItem("Exit");
        exitItem.Click += (_, _) => Dispatcher.Invoke(ExitApp);
        menu.Items.Add(exitItem);

        return menu;
    }

    private void OnStateChanged(object? sender, AppState state)
    {
        Dispatcher.Invoke(() =>
        {
            switch (state)
            {
                case AppState.Recording:
                    if (_trayIcon != null) _trayIcon.Text = "STTpro - Recording...";
                    var hwnd = _orchestrator?.RecordingTargetHwnd ?? IntPtr.Zero;
                    _recordingIndicator?.ShowForWindow(hwnd);
                    break;
                case AppState.Transcribing:
                    if (_trayIcon != null) _trayIcon.Text = "STTpro - Transcribing...";
                    // Keep indicator visible but change to "processing" mode
                    _borderOverlay?.Hide();
                    _recordingIndicator?.SetPromptLabel("Transcribing...");
                    break;
                case AppState.PostProcessing:
                    if (_trayIcon != null) _trayIcon.Text = "STTpro - Processing...";
                    _recordingIndicator?.SetPromptLabel("Processing...");
                    break;
                case AppState.Idle:
                    if (_trayIcon != null) _trayIcon.Text = "STTpro - Speech to Text";
                    _recordingIndicator?.Hide();
                    _borderOverlay?.Hide();
                    break;
            }
        });
    }

    private void OnPromptChanged(object? sender, string? promptName)
    {
        Dispatcher.Invoke(() =>
        {
            if (promptName != null)
            {
                _recordingIndicator?.SetPromptLabel(promptName);
                _promptToast?.ShowToast($"Recording with: {promptName}");
            }
            else
            {
                _recordingIndicator?.SetPromptLabel("");
            }
        });
    }

    private void ShowSettings()
    {
        // If window already exists, restore and activate it
        if (_settingsWindow != null)
        {
            if (_settingsWindow.WindowState == WindowState.Minimized)
                _settingsWindow.WindowState = WindowState.Normal;
            _settingsWindow.Activate();
            return;
        }

        var settings = _serviceProvider!.GetRequiredService<ISettingsService>();
        var credStore = _serviceProvider!.GetRequiredService<DpapiCredentialStore>();
        var audio = _serviceProvider!.GetRequiredService<IAudioCaptureService>();
        var hotkeyService = _serviceProvider!.GetRequiredService<IGlobalHotkeyService>();
        var history = _serviceProvider!.GetRequiredService<ITranscriptRepository>();

        _settingsWindow = new SettingsWindow(settings, credStore, audio, hotkeyService, history);
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        ThemeManager.RegisterWindow(_settingsWindow);
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void ShowHistory()
    {
        var history = _serviceProvider!.GetRequiredService<ITranscriptRepository>();
        var output = _serviceProvider!.GetRequiredService<ITextOutputService>();
        var settings = _serviceProvider!.GetRequiredService<ISettingsService>();

        var window = new HistoryWindow(history, output, settings);
        ThemeManager.RegisterWindow(window);
        window.Show();
    }

    private void ExitApp()
    {
        _orchestrator?.Dispose();
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null;
        }
        _recordingIndicator?.Close();
        _borderOverlay?.Close();
        _promptToast?.Close();
        _serviceProvider?.Dispose();
        Shutdown();
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        FileLogger.Error("Unhandled dispatcher exception", e.Exception);
        e.Handled = true; // Prevent crash for recoverable UI exceptions

        try
        {
            _notifications?.ShowError($"Unexpected error: {e.Exception.Message}");
        }
        catch { /* notification service may itself be broken */ }

        // If the app is in a bad state (e.g. recording stuck), reset to idle
        try
        {
            if (_orchestrator?.State != AppState.Idle)
            {
                FileLogger.Info("Resetting orchestrator to Idle after unhandled exception");
                _orchestrator?.CancelRecordingFromUI();
            }
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed to reset state after exception", ex);
        }
    }

    private void OnAppDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        var ex = e.ExceptionObject as Exception ?? new Exception(e.ExceptionObject?.ToString() ?? "Unknown fatal error");
        FileLogger.Error($"Fatal unhandled exception (terminating={e.IsTerminating})", ex);

        if (e.IsTerminating)
        {
            RestartApp();
        }
    }

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        FileLogger.Error("Unobserved task exception", e.Exception);
        e.SetObserved(); // Prevent process termination from background task failures
    }

    private static void RestartApp()
    {
        if (_isRestarting) return;
        _isRestarting = true;

        try
        {
            var exePath = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exePath))
            {
                FileLogger.Info($"Auto-restarting STTpro: {exePath}");
                Process.Start(new ProcessStartInfo
                {
                    FileName = exePath,
                    UseShellExecute = true
                });
            }
            else
            {
                FileLogger.Error("Cannot restart: unable to determine executable path", new InvalidOperationException("ProcessPath is null"));
            }
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed to restart app", ex);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        }
        try { _singleInstanceMutex?.ReleaseMutex(); } catch { }
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }
}
