import Foundation
import Testing
@testable import STTproCore

@Suite struct PunctuationReplacerTests {
    @Test func englishWords() {
        #expect(PunctuationReplacer.apply("hello comma world period") == "hello, world.")
        #expect(PunctuationReplacer.apply("is it question mark") == "is it?")
    }

    @Test func hebrewWords() {
        #expect(PunctuationReplacer.apply("שלום פסיק מה נשמע סימן שאלה") == "שלום, מה נשמע?")
        // "נקודה פסיק" must become ";" rather than ". ,"
        #expect(PunctuationReplacer.apply("א נקודה פסיק ב") == "א; ב")
    }

    @Test func frenchOnlyWhenFrench() {
        #expect(PunctuationReplacer.apply("the point is clear") == "the point is clear")
        #expect(PunctuationReplacer.apply("bonjour virgule ça va point", language: "french") == "bonjour, ça va.")
    }

    @Test func wordBoundaries() {
        #expect(PunctuationReplacer.apply("periodically") == "periodically")
    }

    @Test func trailingPeriod() {
        #expect(PunctuationReplacer.addTrailingPeriod("hello") == "hello.")
        #expect(PunctuationReplacer.addTrailingPeriod("hello?") == "hello?")
        #expect(PunctuationReplacer.addTrailingPeriod("שלום") == "שלום.")
    }
}

@Suite struct ProviderTests {
    @Test func sttRequestShape() throws {
        let stt = OpenAICompatibleSTT(baseUrl: "https://api.groq.com/openai/v1/", apiKey: "test-key", model: "whisper-large-v3")
        let req = try stt.makeRequest(audio: Data([1, 2, 3]), language: "he")
        #expect(req.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        #expect(body.contains("name=\"language\"\r\n\r\nhe"))
        #expect(body.contains("verbose_json"))
        #expect(body.contains("filename=\"audio.wav\""))
    }

    @Test func gpt4oTranscribeUsesJson() {
        #expect(OpenAICompatibleSTT(baseUrl: "https://x/v1", apiKey: nil, model: "gpt-4o-transcribe").responseFormat == "json")
    }

    @Test func parseVerboseJson() throws {
        let json = """
        {"text":" Hello there ","language":"english","duration":2.0,
         "segments":[{"start":0,"end":1.5,"no_speech_prob":0.1},{"start":1.5,"end":2.0,"no_speech_prob":0.9}]}
        """
        let r = try OpenAICompatibleSTT.parse(Data(json.utf8))
        #expect(r.text == "Hello there")
        #expect(r.detectedLanguage == "english")
        #expect(abs(r.noSpeechProbability - 0.3) < 0.0001)
    }

    @Test func llmOmitsTemperatureForReasoningModels() throws {
        let req = try OpenAICompatibleLLM(baseUrl: "https://api.openai.com/v1", apiKey: "k", model: "o4-mini")
            .makeRequest(text: "hi", systemPrompt: "sys")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["temperature"] == nil)
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func effectiveBaseUrl() {
        var c = ApiProviderConfig(providerType: "groq", apiKeySlot: "groq", model: "m")
        #expect(ApiProviders.effectiveBaseUrl(c, isStt: true) == "https://api.groq.com/openai/v1")
        c.baseUrl = "http://localhost:8000/v1"
        #expect(ApiProviders.effectiveBaseUrl(c, isStt: true) == "http://localhost:8000/v1")
    }
}

@Suite struct SettingsAndHistoryTests {
    @Test func settingsToleratesMissingKeys() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"languageHint":"he","addTrailingPeriod":false}"#.utf8))
        #expect(s.languageHint == "he")
        #expect(s.addTrailingPeriod == false)
        #expect(s.holdToTalkHotkey == .defaultHoldToTalk)
        #expect(s.prompts.count == 3)
    }

    @Test func defaultHotkeyLabels() {
        #expect(HotkeyBinding.defaultHoldToTalk.displayName == "⌃Space")
        #expect(HotkeyBinding.defaultPrompt(index: 0)?.displayName == "⌃⇧1")
    }

    @Test func historyRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sttpro-test-\(UUID()).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        store.save(TranscriptRecord(text: "first", detectedLanguage: "english"))
        let id = store.save(TranscriptRecord(text: "שלום עולם", detectedLanguage: "hebrew", promptName: "Organize", originalText: "raw"))
        #expect(id > 0)
        #expect(store.latest()?.text == "שלום עולם")
        #expect(store.search("עולם").count == 1)
        #expect(store.recent().count == 2)
        store.prune(keeping: 1)
        #expect(store.count() == 1)
        store.delete(id: id)
        #expect(store.count() == 0)
    }
}
