# STTpro

**Speech to text, everywhere you type.**

STTpro is a lightweight Windows tray app that turns your voice into text in any application. Hold a hotkey, speak, and the transcription is pasted straight into whatever you're typing — editor, browser, chat, terminal. Optional LLM post-processing ("Smart Prompts") can clean up, translate, or reformat what you said on the fly.

| Light | Dark |
| :---: | :---: |
| ![STTpro — light theme](docs/screenshot-light.png) | ![STTpro — dark theme](docs/screenshot-dark.png) |

<sub>The UI follows your Windows light/dark setting automatically.</sub>

## Features

- 🎙️ **Push-to-talk transcription** — hold a global hotkey to record, release to transcribe and paste.
- 🔁 **Toggle & paste-last hotkeys** — start/stop hands-free, or re-paste your last transcription.
- 🧠 **Smart Prompts** — post-process a recording through an LLM (e.g. "clean up grammar", "translate to English", "make it a bullet list"), each bound to its own hotkey.
- 🔌 **Bring your own provider** — configurable STT and LLM providers/models with custom base URLs (OpenAI-compatible endpoints, local servers, etc.).
- ⌨️ **Flexible output** — clipboard paste, direct Unicode typing, copy-only, or save-to-history.
- 🌐 **Multi-language** — auto-detect or pin a language (English, Hebrew, French, Spanish, German, Arabic, Russian, …).
- 🕘 **Local history** — every transcription stored locally in SQLite; search, copy, export (JSON/text). Nothing is sent anywhere except your chosen API provider.
- 📊 **Usage & cost estimate** — track transcription count, audio minutes, and approximate spend.
- 🌗 **Light & dark theme** — follows your Windows appearance setting automatically, including native title bars.
- 🔒 **Secure key storage** — API keys are encrypted at rest with Windows DPAPI, never written to the repo or history.
- 🚀 **Runs in the tray** — optional launch on Windows startup, minimal footprint.

## Requirements

- Windows 10 (1809+) or Windows 11
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (to build) or the .NET 8 Desktop Runtime (to run a published build)
- An API key for a supported speech-to-text provider (and an LLM provider if you use Smart Prompts)

## Build & run

```bash
# from the repo root
dotnet build STTpro.sln -c Release

# run the app
dotnet run --project src/STTpro.App -c Release
```

On first launch the Settings window opens automatically so you can pick a provider and paste your API key. After that, STTpro lives in the system tray — left-click the tray icon for Settings, right-click for the menu.

### Default hotkeys

| Action | Shortcut |
| --- | --- |
| Hold to talk | `Ctrl + Space` |
| Toggle recording | `Ctrl + Shift + Space` |
| Paste last transcription | `Ctrl + Shift + V` |
| Smart Prompt 1–9 | `Ctrl + Shift + 1…9` |

All hotkeys are rebindable in **Settings → Hotkeys**.

## macOS (menu-bar app)

A native Swift/SwiftUI version lives in [`mac/`](mac/) and is independent of the Windows code. It runs in the menu bar (microphone icon, no Dock icon) and covers the core loop: push-to-talk, toggle recording, paste last transcript, Smart Prompts, OpenAI-compatible STT/LLM providers with custom base URLs, local SQLite history, and Hebrew/multi-language support.

**Requirements:** Apple Silicon Mac, macOS 14 or later, and either full Xcode or just the Command Line Tools (`xcode-select --install`).

```bash
cd mac
scripts/build-app.sh            # builds mac/build/STTpro.app
scripts/build-app.sh --install  # also copies it to /Applications (needed for "Launch at login")
open build/STTpro.app
swift run STTproCoreChecks       # unit checks: providers, punctuation, history (no Xcode needed)
```

The script uses `xcodebuild` when full Xcode is installed (or `BUILD_TOOL=xcodebuild`) and SwiftPM otherwise. You can also open `mac/Package.swift` in Xcode.

**First run.** The Settings window opens with a *Finish setup* card at the top that walks you through:

1. **Microphone.** macOS asks the first time you record. The mic is on only while you're dictating.
2. **Accessibility.** Lets STTpro press ⌘V in the app you're typing in. Turn on STTpro under *System Settings › Privacy & Security › Accessibility*. Without it, the text is left on the clipboard for you to paste.
3. **API key.** Go to *Settings › Providers*, choose a provider, paste your key, and click Save. Keys are stored only in your login Keychain (item "STTpro API Key"), never in files, logs or the repo.

| Action | Default shortcut |
| --- | --- |
| Hold to talk | `⌃ Space` |
| Toggle recording | `⌃⇧ Space` |
| Paste last transcription | `⌃⇧ V` |
| Smart Prompt 1–9 | `⌃⇧ 1…9` |

> **⌃Space and keyboard languages:** if you use more than one input source (e.g. English + Hebrew), macOS already uses ⌃Space for *Select the previous input source*. STTpro detects this and offers to switch to `⌥ Space`. You can also turn the macOS shortcut off in *System Settings › Keyboard › Keyboard Shortcuts › Input Sources* and switch languages with the 🌐 Globe key instead.

**Where things live:** settings are in `~/Library/Application Support/STTpro/settings.json`, history in `~/Library/Application Support/STTpro/history.db` (same schema as Windows), and logs in `~/Library/Logs/STTpro/sttpro.log`.

**Keeping permissions across rebuilds:** local builds are ad-hoc signed by default, and macOS ties the Accessibility grant to that exact build. After a rebuild the toggle in System Settings can still look on while STTpro is no longer trusted. Run this once to create a local signing certificate (macOS asks for your password to trust it):

```bash
scripts/create-signing-cert.sh   # one time
scripts/build-app.sh --install   # now signs with "STTpro Local Code Signing"
```

If Accessibility already looks on but Settings still shows it red, click **Reset & ask again**, switch STTpro on, then click **Relaunch STTpro** (all in the *Finish setup* card). To use an Apple Development certificate instead: `SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh --install`.

**Look and feel:** the Mac UI reuses the Windows palette (`Themes/Palette.*.xaml`), card layout, tabs, buttons and recording pill. That includes the live waveform, "no mic signal" warning, stop/cancel buttons and the "Recording with: …" prompt toast. Light and dark follow macOS, or you can choose one under *Options › Appearance*.

**Differences from Windows, and why:**

| Windows | macOS | Why |
| --- | --- | --- |
| Blue tray icon | Monochrome 🎙 menu-bar icon, red while recording | macOS menu-bar icons are template images that adapt to the menu-bar color |
| Segoe UI | SF Pro (system font) | Segoe UI isn't available on macOS |
| Tray balloon notifications | Short messages in the recording pill | Avoids asking for notification permission |
| Direct Unicode typing output | Not offered | Paste via ⌘V is reliable on macOS, including Hebrew |
| Silence-based chunked transcription, 300 ms pre-roll | Not yet | The mic is opened only while you dictate (no always-on buffer) |
| Red border around the target window | Not ported | On Windows it is created but never shown |
| — | *Finish setup* (Permissions) card | macOS needs Microphone and Accessibility consent |

`STTpro --snapshot <dir>` renders the Settings, History and pill views to PNGs in light and dark, for checking visuals without screen recording.

## Project layout

| Project | Responsibility |
| --- | --- |
| `STTpro.App` | WPF UI, tray, overlays, and the centralized theme system (`Themes/`, `Theme/ThemeManager.cs`) |
| `STTpro.Core` | Audio capture, STT/LLM providers, hotkeys, history, settings, secure storage |
| `STTpro.Interop` | Win32 interop helpers |
| `STTpro.Core.Tests` | Unit tests |
| `mac/` | Native macOS menu-bar app (Swift Package: `STTproCore` + `STTpro`) |

## Privacy

Audio is streamed only to the STT/LLM provider you configure. Transcriptions and settings are stored **locally** on your device; API keys are encrypted with Windows DPAPI. STTpro has no telemetry and no backend of its own.

## License

[MIT](LICENSE) © Nir Lever
