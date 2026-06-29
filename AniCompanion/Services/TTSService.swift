import Foundation

// MARK: - Errors

enum TTSError: LocalizedError {
    case invalidURL
    case requestFailed(statusCode: Int, body: String)
    case invalidResponse
    case decodingError(String)
    case invalidHexData
    case apiError(statusCode: Int, message: String)
    case emptyText
    case unauthorized
    case missingCredentials(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid TTS API endpoint URL."
        case .requestFailed(let statusCode, let body):
            return "TTS request failed with status \(statusCode): \(body)"
        case .invalidResponse:
            return "Received an invalid response from the TTS server."
        case .decodingError(let detail):
            return "Failed to decode TTS response: \(detail)"
        case .invalidHexData:
            return "Received invalid hex-encoded audio data."
        case .apiError(let statusCode, let message):
            return "MiniMax API error (\(statusCode)): \(message)"
        case .emptyText:
            return "Cannot synthesize empty text."
        case .unauthorized:
            return "Invalid or missing TTS API key."
        case .missingCredentials(let provider):
            return "\(provider) TTS is selected but its required credentials are missing."
        }
    }
}

// MARK: - Provider

enum TTSProvider: String, CaseIterable, Identifiable, Sendable {
    case miniMax
    case openAI
    case groq

    var id: String { rawValue }

    static let storageKey = "tts_provider"

    var displayName: String {
        switch self {
        case .miniMax: return "MiniMax"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        }
    }

    static var current: TTSProvider {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let provider = TTSProvider(rawValue: raw) {
            return provider
        }
        return .miniMax
    }
}

// MARK: - Protocol

struct TTSAudioStream: @unchecked Sendable {
    enum Format: Sendable, Equatable {
        case encoded
        case pcm16(sampleRate: Double, channels: Int)
    }

    let format: Format
    let chunks: AsyncThrowingStream<Data, Error>
}

protocol TTSServiceProtocol: Sendable {
    var outputFormat: TTSAudioStream.Format { get }

    func synthesize(text: String, emotion: Emotion) -> TTSAudioStream
}

// MARK: - Implementation

final class TTSService: TTSServiceProtocol, Sendable {
    private let provider: TTSProvider
    private let miniMaxAPIKey: String
    private let miniMaxGroupID: String
    private let miniMaxVoiceID: String
    private let miniMaxModel: String
    private let openAIAPIKey: String
    private let openAIModel: String
    private let openAIVoice: String
    private let openAIInstructions: String
    private let groqAPIKey: String
    private let groqModel: String
    private let groqVoice: String
    private let session: URLSession

    var outputFormat: TTSAudioStream.Format {
        switch provider {
        case .openAI:
            return .pcm16(sampleRate: 24_000, channels: 1)
        case .miniMax, .groq:
            return .encoded
        }
    }

    init(
        provider: TTSProvider = .miniMax,
        miniMaxAPIKey: String,
        miniMaxGroupID: String,
        miniMaxVoiceID: String = "Chinese (Mandarin)_Crisp_Girl",
        miniMaxModel: String = "speech-02-turbo",
        openAIAPIKey: String = "",
        openAIModel: String = "gpt-4o-mini-tts",
        openAIVoice: String = "coral",
        openAIInstructions: String = "Speak warmly and expressively, like a friendly anime companion.",
        groqAPIKey: String = "",
        groqModel: String = "canopylabs/orpheus-v1-english",
        groqVoice: String = "troy"
    ) {
        self.provider = provider
        self.miniMaxAPIKey = miniMaxAPIKey
        self.miniMaxGroupID = miniMaxGroupID
        self.miniMaxVoiceID = miniMaxVoiceID
        self.miniMaxModel = miniMaxModel
        self.openAIAPIKey = openAIAPIKey
        self.openAIModel = openAIModel
        self.openAIVoice = openAIVoice
        self.openAIInstructions = openAIInstructions
        self.groqAPIKey = groqAPIKey
        self.groqModel = groqModel
        self.groqVoice = groqVoice

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func synthesize(text: String, emotion: Emotion) -> TTSAudioStream {
        let format = outputFormat
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.finish(throwing: TTSError.emptyText)
                        return
                    }

                    switch provider {
                    case .miniMax:
                        try await synthesizeMiniMax(text: text, emotion: emotion, continuation: continuation)
                    case .openAI:
                        try await synthesizeOpenAI(text: text, emotion: emotion, continuation: continuation)
                    case .groq:
                        let data = try await synthesizeGroq(text: text, emotion: emotion)
                        continuation.yield(data)
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return TTSAudioStream(format: format, chunks: chunks)
    }

    // MARK: - MiniMax

    private func synthesizeMiniMax(
        text: String,
        emotion: Emotion,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        guard !miniMaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !miniMaxGroupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSError.missingCredentials("MiniMax")
        }

        let request = try buildMiniMaxRequest(text: text, emotion: emotion)
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 2000 { break }
            }

            if httpResponse.statusCode == 401 {
                throw TTSError.unauthorized
            }
            throw TTSError.requestFailed(statusCode: httpResponse.statusCode, body: errorBody)
        }

        for try await line in bytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            // Handle non-SSE error responses (plain JSON without "data:" prefix).
            if trimmedLine.hasPrefix("{"), !trimmedLine.hasPrefix("data:") {
                if let jsonData = trimmedLine.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let baseResp = json["base_resp"] as? [String: Any],
                   let statusCode = baseResp["status_code"] as? Int,
                   statusCode != 0 {
                    let message = baseResp["status_msg"] as? String ?? "Unknown error"
                    throw TTSError.apiError(statusCode: statusCode, message: message)
                }
                continue
            }

            guard trimmedLine.hasPrefix("data:") else { continue }

            // Handle both "data: {...}" and "data:{...}" formats.
            let payload: String
            if line.hasPrefix("data: ") {
                payload = String(line.dropFirst(6))
            } else {
                payload = String(line.dropFirst(5))
            }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let baseResp = json["base_resp"] as? [String: Any],
               let statusCode = baseResp["status_code"] as? Int,
               statusCode != 0 {
                let message = baseResp["status_msg"] as? String ?? "Unknown error"
                throw TTSError.apiError(statusCode: statusCode, message: message)
            }

            // MiniMax streaming T2A v2 sends incremental audio chunks, then
            // a final event containing the COMPLETE audio. The final event
            // has "extra_info" at the top level. Skip it to avoid doubling.
            if json["extra_info"] != nil {
                continue
            }

            guard let dataObject = json["data"] as? [String: Any],
                  let hexString = dataObject["audio"] as? String,
                  !hexString.isEmpty else {
                continue
            }

            guard let audioData = Data(hexString: hexString) else {
                throw TTSError.invalidHexData
            }

            continuation.yield(audioData)
        }

        continuation.finish()
    }

    private func buildMiniMaxRequest(text: String, emotion: Emotion) throws -> URLRequest {
        let urlString = "https://api.minimax.io/v1/t2a_v2?GroupId=\(miniMaxGroupID)"
        guard let url = URL(string: urlString) else {
            throw TTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(miniMaxAPIKey)", forHTTPHeaderField: "Authorization")

        var voiceSetting: [String: Any] = [
            "voice_id": miniMaxVoiceID,
            "speed": 1.0
        ]

        if emotion.ttsEmotionCategory != nil {
            voiceSetting["timber_weights"] = [
                ["timber_id": miniMaxVoiceID, "weight": 100]
            ]
        }

        let body: [String: Any] = [
            "model": miniMaxModel,
            "text": text,
            "stream": true,
            "voice_setting": voiceSetting,
            "audio_setting": [
                "sample_rate": 32000,
                "bitrate": 128000,
                "format": "mp3"
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - OpenAI

    private func synthesizeOpenAI(
        text: String,
        emotion: Emotion,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        guard !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSError.missingCredentials("OpenAI")
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw TTSError.invalidURL
        }

        var body: [String: Any] = [
            "model": openAIModel,
            "input": text,
            "voice": openAIVoice,
            "response_format": "pcm"
        ]

        let instructions = openAIInstructionsForRequest(emotion: emotion)
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }

        var request = try buildJSONRequest(url: url, apiKey: openAIAPIKey, body: body)
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw TTSError.unauthorized
            }
            let body = try await readErrorBody(from: bytes)
            throw TTSError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        var audioChunk = Data()
        audioChunk.reserveCapacity(8192)

        for try await byte in bytes {
            try Task.checkCancellation()
            audioChunk.append(byte)
            if audioChunk.count >= 8192 {
                continuation.yield(audioChunk)
                audioChunk.removeAll(keepingCapacity: true)
            }
        }

        if !audioChunk.isEmpty {
            continuation.yield(audioChunk)
        }

        continuation.finish()
    }

    private func openAIInstructionsForRequest(emotion: Emotion) -> String {
        var parts = [openAIInstructions.trimmingCharacters(in: .whitespacesAndNewlines)]
        if emotion != .neutral {
            parts.append("Current emotional tone: \(emotion.rawValue).")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Groq

    private func synthesizeGroq(text: String, emotion: Emotion) async throws -> Data {
        guard !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSError.missingCredentials("Groq")
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/audio/speech") else {
            throw TTSError.invalidURL
        }

        let body: [String: Any] = [
            "model": groqModel,
            "input": groqInput(text: text, emotion: emotion),
            "voice": groqVoice,
            "response_format": "wav"
        ]

        return try await fetchSpeechAudio(url: url, apiKey: groqAPIKey, body: body)
    }

    private func groqInput(text: String, emotion: Emotion) -> String {
        guard let direction = groqDirection(for: emotion) else {
            return text
        }
        return "[\(direction)] \(text)"
    }

    private func groqDirection(for emotion: Emotion) -> String? {
        switch emotion {
        case .happy, .excited, .love, .proud, .laugh:
            return "cheerful"
        case .sad, .pain:
            return "sad"
        case .angry, .disgusted:
            return "angry"
        case .surprised:
            return "surprised"
        case .curious:
            return "curious"
        case .shy:
            return "softly"
        case .sleepy, .bored:
            return "calm"
        case .smirk:
            return "playful"
        case .neutral:
            return nil
        }
    }

    // MARK: - Shared HTTP

    private func fetchSpeechAudio(url: URL, apiKey: String, body: [String: Any]) async throws -> Data {
        let request = try buildJSONRequest(url: url, apiKey: apiKey, body: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw TTSError.unauthorized
            }
            let body = String(data: data.prefixData(2000), encoding: .utf8) ?? ""
            throw TTSError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        return data
    }

    private func buildJSONRequest(url: URL, apiKey: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        data.reserveCapacity(2000)

        for try await byte in bytes {
            data.append(byte)
            if data.count >= 2000 {
                break
            }
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension Data {
    func prefixData(_ maxLength: Int) -> Data {
        guard count > maxLength else { return self }
        return subdata(in: 0..<maxLength)
    }
}

// MARK: - Hex Decoding

extension Data {
    /// Initialize Data from a hex-encoded string (e.g., "48656c6c6f" -> bytes for "Hello").
    /// Returns nil if the string contains invalid hex characters or has an odd length.
    init?(hexString: String) {
        let chars = Array(hexString)
        let length = chars.count

        // Hex string must have even length.
        guard length % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(length / 2)

        var index = 0
        while index < length {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue else {
                return nil
            }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }

        self.init(bytes)
    }
}

private extension Character {
    /// Convert a single hex character to its integer value (0-15), or nil if invalid.
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return Int(asciiValue! - Character("a").asciiValue!) + 10
        case "A"..."F": return Int(asciiValue! - Character("A").asciiValue!) + 10
        default: return nil
        }
    }
}
