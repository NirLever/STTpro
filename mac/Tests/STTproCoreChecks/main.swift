import Foundation
import STTproCore

// Core unit checks. Run with:  swift run STTproCoreChecks
// A plain executable instead of swift-testing/XCTest, because their macro
// plugins / frameworks ship only with full Xcode, not the Command Line Tools.

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition() {
        passed += 1
    } else {
        failures += 1
        print("✘ \(message)  (\(file):\(line))")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch { failures += 1; print("✘ \(name) threw: \(error)") }
    print(failures == before ? "✔ \(name)" : "✘ \(name)")
}

// MARK: - Punctuation

test("English punctuation words") {
    check(PunctuationReplacer.apply("hello comma world period") == "hello, world.", "comma/period")
    check(PunctuationReplacer.apply("is it question mark") == "is it?", "question mark")
}

test("Hebrew punctuation words") {
    check(PunctuationReplacer.apply("שלום פסיק מה נשמע סימן שאלה") == "שלום, מה נשמע?", "comma/question")
    check(PunctuationReplacer.apply("א נקודה פסיק ב") == "א; ב", "נקודה פסיק → ;")
}

test("French words only when French") {
    check(PunctuationReplacer.apply("the point is clear") == "the point is clear", "English 'point' untouched")
    check(PunctuationReplacer.apply("bonjour virgule ça va point", language: "french") == "bonjour, ça va.", "French rules")
}

test("Word boundaries") {
    check(PunctuationReplacer.apply("periodically") == "periodically", "no partial match")
}

test("Trailing period") {
    check(PunctuationReplacer.addTrailingPeriod("hello") == "hello.", "adds period")
    check(PunctuationReplacer.addTrailingPeriod("hello?") == "hello?", "keeps ?")
    check(PunctuationReplacer.addTrailingPeriod("שלום") == "שלום.", "Hebrew")
}

// MARK: - Providers

test("STT request shape") {
    let stt = OpenAICompatibleSTT(baseUrl: "https://api.groq.com/openai/v1/", apiKey: "test-key", model: "whisper-large-v3")
    let req = try stt.makeRequest(audio: Data([1, 2, 3]), language: "he")
    check(req.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions", "endpoint")
    check(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "auth header")
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    check(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3"), "model field")
    check(body.contains("name=\"language\"\r\n\r\nhe"), "language field")
    check(body.contains("verbose_json"), "verbose_json for whisper")
    check(body.contains("filename=\"audio.wav\""), "file part")
}

test("gpt-4o-transcribe uses json") {
    check(OpenAICompatibleSTT(baseUrl: "https://x/v1", apiKey: nil, model: "gpt-4o-transcribe").responseFormat == "json", "json format")
}

test("Parse verbose_json") {
    let json = """
    {"text":" Hello there ","language":"english","duration":2.0,
     "segments":[{"start":0,"end":1.5,"no_speech_prob":0.1},{"start":1.5,"end":2.0,"no_speech_prob":0.9}]}
    """
    let r = try OpenAICompatibleSTT.parse(Data(json.utf8))
    check(r.text == "Hello there", "trimmed text")
    check(r.detectedLanguage == "english", "language")
    check(abs(r.noSpeechProbability - 0.3) < 0.0001, "weighted no_speech_prob")
}

test("LLM omits temperature for reasoning models") {
    let req = try OpenAICompatibleLLM(baseUrl: "https://api.openai.com/v1", apiKey: "k", model: "o4-mini")
        .makeRequest(text: "hi", systemPrompt: "sys")
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    check(body["temperature"] == nil, "no temperature")
    check(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions", "endpoint")
}

test("Effective base URL") {
    var c = ApiProviderConfig(providerType: "groq", apiKeySlot: "groq", model: "m")
    check(ApiProviders.effectiveBaseUrl(c, isStt: true) == "https://api.groq.com/openai/v1", "preset default")
    c.baseUrl = "http://localhost:8000/v1"
    check(ApiProviders.effectiveBaseUrl(c, isStt: true) == "http://localhost:8000/v1", "override")
}

// MARK: - Settings & history

test("Settings tolerate missing keys") {
    let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"languageHint":"he","addTrailingPeriod":false}"#.utf8))
    check(s.languageHint == "he", "languageHint")
    check(s.addTrailingPeriod == false, "addTrailingPeriod")
    check(s.holdToTalkHotkey == .defaultHoldToTalk, "default hotkey kept")
    check(s.prompts.count == 3, "default prompts kept")
}

test("Default hotkey labels") {
    check(HotkeyBinding.defaultHoldToTalk.displayName == "⌃Space", "⌃Space")
    check(HotkeyBinding.defaultPrompt(index: 0)?.displayName == "⌃⇧1", "⌃⇧1")
}

test("History round trip") {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sttpro-test-\(UUID()).db")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try HistoryStore(url: url)
    store.save(TranscriptRecord(text: "first", detectedLanguage: "english"))
    let id = store.save(TranscriptRecord(text: "שלום עולם", detectedLanguage: "hebrew", promptName: "Organize", originalText: "raw"))
    check(id > 0, "insert id")
    check(store.latest()?.text == "שלום עולם", "latest")
    check(store.search("עולם").count == 1, "search")
    check(store.recent().count == 2, "recent")
    store.prune(keeping: 1)
    check(store.count() == 1, "prune")
    store.delete(id: id)
    check(store.count() == 0, "delete")
}

print("\n\(passed) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
