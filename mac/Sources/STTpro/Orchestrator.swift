import AppKit
import AVFoundation
import STTproCore

/// The core loop (port of AppOrchestrator.cs): hotkey → record → STT →
/// optional Smart Prompt → paste → history.
@MainActor
final class Orchestrator: ObservableObject {
    enum State: Equatable { case idle, recording, transcribing, postProcessing }

    @Published private(set) var state: State = .idle
    @Published private(set) var activePromptName: String?

    private let store: SettingsStore
    private let history: HistoryStore?
    private let recorder = AudioRecorder()
    let hud = RecordingHUD()

    /// Called when the user needs to fix something in Settings (e.g. API key).
    var openSettings: ((SettingsTab) -> Void)?

    private var isToggleRecording = false
    private var holdActive = false
    private var selectedPromptIndex: Int?
    private var targetApp: NSRunningApplication?

    init(store: SettingsStore, history: HistoryStore?) {
        self.store = store
        self.history = history
        recorder.prewarm()
    }

    private var settings: AppSettings { store.settings }

    // MARK: - Hotkey entry points

    func holdPressed() {
        guard state == .idle else { return }
        isToggleRecording = false
        holdActive = true
        startRecording()
    }

    func holdReleased() {
        guard holdActive else { return }
        holdActive = false
        guard state == .recording, !isToggleRecording else { return }
        stopAndTranscribe()
    }

    func togglePressed() {
        switch state {
        case .idle:
            isToggleRecording = true
            startRecording()
        case .recording where isToggleRecording:
            stopAndTranscribe()
        default:
            break
        }
    }

    func promptPressed(_ index: Int) {
        let prompts = settings.enabledPromptBindings
        guard prompts.indices.contains(index) else { return }
        let hold = settings.promptHotkeyMode == .hold

        if state == .recording {
            if selectedPromptIndex == index && !hold {
                stopAndTranscribe()
            } else if selectedPromptIndex != index {
                selectedPromptIndex = index
                activePromptName = prompts[index].prompt.name
                hud.show(.recording(prompt: activePromptName))
            }
            return
        }
        guard state == .idle else { return }
        selectedPromptIndex = index
        activePromptName = prompts[index].prompt.name
        isToggleRecording = !hold
        startRecording()
    }

    func promptReleased(_ index: Int) {
        guard state == .recording, settings.promptHotkeyMode == .hold, selectedPromptIndex == index else { return }
        stopAndTranscribe()
    }

    func pasteLast() {
        guard state == .idle else { return }
        guard let latest = history?.latest() else {
            hud.show(.message("No transcript in history yet.", isError: false))
            return
        }
        let target = NSWorkspace.shared.frontmostApplication
        Task {
            do {
                try await PasteService.paste(latest.text, into: target, restoreClipboard: settings.restoreClipboard)
            } catch {
                hud.show(.message(error.localizedDescription, isError: true))
            }
        }
    }

    /// Menu-bar "Start/Stop recording".
    func toggleFromMenu() { togglePressed() }

    func cancelRecording() {
        guard state == .recording else { return }
        recorder.cancel()
        resetPrompt()
        setState(.idle)
        hud.hide()
    }

    // MARK: - Recording

    private func startRecording() {
        switch Permissions.microphone {
        case .authorized:
            break
        case .notDetermined:
            resetPrompt()
            Task {
                let granted = await Permissions.requestMicrophone()
                hud.show(.message(granted ? "Microphone enabled — press the hotkey again." : "Microphone access denied.",
                                  isError: !granted))
                if granted { recorder.prewarm() }
            }
            return
        default:
            resetPrompt()
            hud.show(.message("Microphone access is off. Turn on STTpro in System Settings › Privacy › Microphone.", isError: true))
            openSettings?(.permissions)
            return
        }

        if store.sttKeyMissing {
            resetPrompt()
            hud.show(.message("Add your speech-to-text API key in Settings.", isError: true))
            openSettings?(.providers)
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        do {
            try recorder.start()
        } catch {
            Log.error("Failed to start recording", error)
            resetPrompt()
            hud.show(.message("Recording error: \(error.localizedDescription)", isError: true))
            return
        }
        Log.info("Recording started (target: \(targetApp?.localizedName ?? "none"))")
        setState(.recording)
        if settings.playSoundCues { NSSound(named: "Tink")?.play() }
        hud.enabled = settings.showRecordingIndicator
        hud.show(.recording(prompt: activePromptName))
    }

    private func stopAndTranscribe() {
        guard state == .recording, let (url, duration) = recorder.stop() else { return }
        if settings.playSoundCues { NSSound(named: "Pop")?.play() }
        Log.info(String(format: "Recording stopped: %.2fs", duration))

        let minSeconds = settings.skipShortRecordings ? Double(settings.minRecordingDurationMs) / 1000 : 0
        if duration < minSeconds {
            try? FileManager.default.removeItem(at: url)
            resetPrompt()
            setState(.idle)
            hud.show(.message("Recording too short.", isError: false))
            return
        }

        setState(.transcribing)
        hud.show(.working("Transcribing…"))
        let promptIndex = selectedPromptIndex
        let target = targetApp
        Task { await process(audioURL: url, recordedSeconds: duration, promptIndex: promptIndex, target: target) }
    }

    private func process(audioURL: URL, recordedSeconds: TimeInterval, promptIndex: Int?, target: NSRunningApplication?) async {
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            resetPrompt()
            setState(.idle)
        }
        let s = settings
        let targetName = target?.localizedName ?? ""

        // 1. Speech to text
        let stt = OpenAICompatibleSTT(
            baseUrl: ApiProviders.effectiveBaseUrl(s.sttProvider, isStt: true),
            apiKey: KeychainStore.load(slot: s.sttProvider.apiKeySlot),
            model: s.sttProvider.model)
        var result: SttResult
        do {
            let audio = try Data(contentsOf: audioURL)
            result = try await stt.transcribe(audio: audio, language: s.languageHint)
            Log.info(String(format: "Transcribed: lang=%@ chars=%d noSpeech=%.3f", result.detectedLanguage, result.text.count, result.noSpeechProbability))
        } catch {
            Log.error("Transcription failed", error)
            hud.show(.message("Transcription failed: \(error.localizedDescription)", isError: true))
            if s.playSoundCues { NSSound(named: "Basso")?.play() }
            history?.save(TranscriptRecord(text: "[Transcription failed: \(error.localizedDescription)]",
                                           providerName: s.sttProvider.providerType, targetWindowName: targetName))
            return
        }

        // 2. Silence / hallucination filter, punctuation words, trailing period
        if result.noSpeechProbability > s.silenceThreshold || result.text.isEmpty {
            hud.show(.message("No speech detected.", isError: false))
            return
        }
        var text = PunctuationReplacer.apply(result.text, language: result.detectedLanguage)
        if s.addTrailingPeriod { text = PunctuationReplacer.addTrailingPeriod(text) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud.show(.message("No speech detected.", isError: false))
            return
        }

        let minutes = (result.duration > 0 ? result.duration : recordedSeconds) / 60
        var usage = s.usage
        usage.transcriptionCount += 1
        usage.totalAudioMinutes += minutes
        usage.totalWhisperCost += minutes * 0.006

        // 3. Smart Prompt post-processing
        var promptName = ""
        var originalText = ""
        var warned = false
        if let promptIndex, s.enabledPromptBindings.indices.contains(promptIndex) {
            let prompt = s.enabledPromptBindings[promptIndex].prompt
            setState(.postProcessing)
            hud.show(.working("\(prompt.name)…"))
            let llm = OpenAICompatibleLLM(
                baseUrl: ApiProviders.effectiveBaseUrl(s.llmProvider, isStt: false),
                apiKey: ApiProviders.requiresApiKey(s.llmProvider.providerType) ? KeychainStore.load(slot: s.effectiveLlmKeySlot) : nil,
                model: s.llmProvider.model)
            do {
                let pp = try await llm.process(text: text, systemPrompt: prompt.prompt)
                originalText = text
                promptName = prompt.name
                text = pp.text
                usage.postProcessTokensIn += pp.inputTokens
                usage.postProcessTokensOut += pp.outputTokens
                usage.totalPostProcessCost += (Double(pp.inputTokens) * 0.15 + Double(pp.outputTokens) * 0.60) / 1_000_000
            } catch {
                Log.error("Post-processing failed", error)
                hud.show(.message("\(prompt.name) failed: \(error.localizedDescription) — pasting raw text.", isError: true))
                warned = true
            }
        }
        store.settings.usage = usage

        // 4. Output
        var inserted = true
        switch s.outputMode {
        case .clipboardPaste:
            do {
                try await PasteService.paste(text, into: target, restoreClipboard: s.restoreClipboard)
            } catch {
                inserted = false
                Log.error("Paste failed", error)
                hud.show(.message(error.localizedDescription, isError: true))
            }
        case .copyOnly:
            PasteService.copy(text)
        case .saveOnly:
            break
        }

        // 5. History
        history?.save(TranscriptRecord(
            text: text, detectedLanguage: result.detectedLanguage, durationSeconds: result.duration,
            providerName: s.sttProvider.providerType, insertionSucceeded: inserted,
            targetWindowName: targetName, promptName: promptName, originalText: originalText))
        history?.prune(keeping: s.maxHistoryItems)
        NotificationCenter.default.post(name: .historyDidChange, object: nil)

        if inserted && !warned {
            hud.show(.message(s.outputMode == .copyOnly ? "Copied" : (s.outputMode == .saveOnly ? "Saved" : "Done"), isError: false))
        }
    }

    private func resetPrompt() {
        selectedPromptIndex = nil
        activePromptName = nil
    }

    private func setState(_ newState: State) {
        state = newState
    }
}

extension Notification.Name {
    static let historyDidChange = Notification.Name("STTpro.historyDidChange")
}
