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

## Project layout

| Project | Responsibility |
| --- | --- |
| `STTpro.App` | WPF UI, tray, overlays, and the centralized theme system (`Themes/`, `Theme/ThemeManager.cs`) |
| `STTpro.Core` | Audio capture, STT/LLM providers, hotkeys, history, settings, secure storage |
| `STTpro.Interop` | Win32 interop helpers |
| `STTpro.Core.Tests` | Unit tests |

## Privacy

Audio is streamed only to the STT/LLM provider you configure. Transcriptions and settings are stored **locally** on your device; API keys are encrypted with Windows DPAPI. STTpro has no telemetry and no backend of its own.

## License

[MIT](LICENSE) © Nir Lever
