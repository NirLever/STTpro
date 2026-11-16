import Foundation

public struct SttResult: Equatable {
    public var text: String
    public var detectedLanguage: String
    public var duration: TimeInterval
    /// Duration-weighted average of segment no_speech_prob (0 when unavailable).
    public var noSpeechProbability: Double
}

public struct PostProcessResult: Equatable {
    public var text: String
    public var inputTokens: Int
    public var outputTokens: Int
}

public enum ProviderError: LocalizedError {
    case missingApiKey(String)
    case invalidBaseUrl(String)
    case http(status: Int, message: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingApiKey(let provider):
            return "No API key for \(provider). Add it in STTpro Settings › Providers."
        case .invalidBaseUrl(let url):
            return "Invalid base URL: \(url)"
        case .http(let status, let message):
            return "HTTP \(status): \(message)"
        case .emptyResponse:
            return "The provider returned an empty response."
        }
    }
}

enum HTTP {
    static func endpoint(_ baseUrl: String, _ path: String) throws -> URL {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + path), url.scheme != nil else {
            throw ProviderError.invalidBaseUrl(baseUrl)
        }
        return url
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, message: errorMessage(from: data))
        }
        return data
    }

    /// Pulls `error.message` out of an OpenAI-style error body.
    static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = obj["error"] as? String { return msg }
            if let msg = obj["message"] as? String { return msg }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.isEmpty ? "Request failed" : text
    }
}

/// POST {baseUrl}/audio/transcriptions — same multipart request the Windows
/// WhisperApiProvider sends.
public struct OpenAICompatibleSTT {
    public let baseUrl: String
    public let apiKey: String?
    public let model: String
    public var session: URLSession = .shared
    public var timeout: TimeInterval = 60

    public init(baseUrl: String, apiKey: String?, model: String) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.model = model
    }

    /// whisper models return verbose_json with no_speech_prob; the newer
    /// gpt-4o-*-transcribe models only accept "json"/"text".
    public var responseFormat: String {
        model.lowercased().contains("whisper") ? "verbose_json" : "json"
    }

    public func makeRequest(audio: Data, filename: String = "audio.wav", language: String?) throws -> URLRequest {
        var request = URLRequest(url: try HTTP.endpoint(baseUrl, "/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var form = MultipartForm()
        form.addFile(name: "file", filename: filename, contentType: "audio/wav", data: audio)
        form.addField(name: "model", value: model)
        if let language, !language.isEmpty { form.addField(name: "language", value: language) }
        form.addField(name: "response_format", value: responseFormat)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalize()
        return request
    }

    public func transcribe(audio: Data, language: String?) async throws -> SttResult {
        let request = try makeRequest(audio: audio, language: language)
        Log.info("STT request: \(request.url?.absoluteString ?? "?") model=\(model) lang=\(language ?? "auto") bytes=\(audio.count)")
        let data = try await HTTP.send(request, session: session)
        return try Self.parse(data)
    }

    struct Response: Decodable {
        struct Segment: Decodable {
            var start: Double?
            var end: Double?
            var no_speech_prob: Double?
        }
        var text: String?
        var language: String?
        var duration: Double?
        var segments: [Segment]?
    }

    public static func parse(_ data: Data) throws -> SttResult {
        let r = try JSONDecoder().decode(Response.self, from: data)
        var noSpeech = 0.0
        if let segs = r.segments, !segs.isEmpty {
            var total = 0.0, weighted = 0.0
            for s in segs {
                let dur = max((s.end ?? 0) - (s.start ?? 0), 0.1)
                weighted += (s.no_speech_prob ?? 0) * dur
                total += dur
            }
            noSpeech = total > 0 ? weighted / total : 0
        }
        return SttResult(
            text: (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: r.language ?? "",
            duration: r.duration ?? 0,
            noSpeechProbability: noSpeech)
    }
}

/// POST {baseUrl}/chat/completions — same request as the Windows GptPostProcessor.
public struct OpenAICompatibleLLM {
    public let baseUrl: String
    public let apiKey: String?
    public let model: String
    public var session: URLSession = .shared
    public var timeout: TimeInterval = 60

    public init(baseUrl: String, apiKey: String?, model: String) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.model = model
    }

    /// Reasoning models reject a non-default temperature.
    var sendsTemperature: Bool {
        let m = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return !(m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.hasPrefix("gpt-5"))
    }

    public func makeRequest(text: String, systemPrompt: String) throws -> URLRequest {
        var request = URLRequest(url: try HTTP.endpoint(baseUrl, "/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        if sendsTemperature { body["temperature"] = 0.3 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func process(text: String, systemPrompt: String) async throws -> PostProcessResult {
        let request = try makeRequest(text: text, systemPrompt: systemPrompt)
        Log.info("LLM request: \(request.url?.absoluteString ?? "?") model=\(model) textLength=\(text.count)")
        let data = try await HTTP.send(request, session: session)

        struct Response: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { var content: String? }; var message: Msg? }
            struct Usage: Decodable { var prompt_tokens: Int?; var completion_tokens: Int? }
            var choices: [Choice]?
            var usage: Usage?
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let out = r.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else { throw ProviderError.emptyResponse }
        return PostProcessResult(text: out,
                                 inputTokens: r.usage?.prompt_tokens ?? 0,
                                 outputTokens: r.usage?.completion_tokens ?? 0)
    }
}

struct MultipartForm {
    let boundary = "STTpro-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalize() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}
