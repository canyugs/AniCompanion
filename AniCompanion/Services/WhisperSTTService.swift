import Foundation
import AVFoundation

// MARK: - WhisperSTTService

/// STT provider that records audio locally and transcribes via an OpenAI-compatible
/// Whisper endpoint (`POST /v1/audio/transcriptions`). Covers Groq, OpenAI, and
/// self-hosted Whisper servers.
@MainActor
final class WhisperSTTService: STTServiceProtocol {

    // MARK: - Public State

    private(set) var isListening: Bool = false

    // MARK: - Configuration

    private let endpoint: String
    private let apiKey: String
    private let model: String

    // MARK: - Private State

    private let audioCapture = WhisperAudioCapture()
    private var silenceTimerSource: DispatchSourceTimer?
    private var hasDetectedSound: Bool = false
    private var recordingTask: Task<Void, Never>?
    private var currentAudioURL: URL?

    private let initialSpeechTimeout: TimeInterval = 5.0
    private let silenceTimeout: TimeInterval = 2.0
    // ponytail: 0.03 ignores typical laptop fan / ambient room noise
    private let silenceRMSThreshold: Float = 0.03

    init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - STTServiceProtocol

    func startListening(locale: Locale) -> AsyncThrowingStream<String, Error> {
        // Tear down any previous session to avoid leaking the old continuation.
        tearDown()

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.ensureMicrophoneAccess()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    try Task.checkCancellation()

                    self.isListening = true

                    let onRMS: @Sendable (Float) -> Void = { [weak self] rms in
                        Task { @MainActor [weak self] in
                            guard let self, self.isListening else { return }
                            if rms > self.silenceRMSThreshold {
                                self.hasDetectedSound = true
                                self.resetSilenceTimer()
                            }
                        }
                    }
                    let audioURL = try self.audioCapture.startRecording(onRMS: onRMS)
                    self.currentAudioURL = audioURL
                    self.resetSilenceTimer()

                    await withCheckedContinuation { (stopped: CheckedContinuation<Void, Never>) in
                        self.audioCapture.onStop = { stopped.resume() }
                    }

                    self.isListening = false
                    self.cancelSilenceTimer()

                    let fileData = try Data(contentsOf: audioURL)
                    guard fileData.count > 1000 else {
                        self.cleanupAudioFile()
                        continuation.finish()
                        return
                    }

                    let transcription = try await self.transcribe(audioURL: audioURL, locale: locale)
                    self.cleanupAudioFile()

                    let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        continuation.yield(trimmed)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    self.tearDown()
                    continuation.finish()
                } catch {
                    self.tearDown()
                    continuation.finish(throwing: error)
                }
            }
            self.recordingTask = task

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task { @MainActor in self.tearDown() }
            }
        }
    }

    func stopListening() {
        tearDown()
    }

    // MARK: - Microphone

    private func ensureMicrophoneAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { g in
                    continuation.resume(returning: g)
                }
            }
        }
        guard granted else { throw STTError.notAuthorized }
    }

    // MARK: - Transcription

    private func transcribe(audioURL: URL, locale: Locale) async throws -> String {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/v1/audio/transcriptions") else {
            throw STTError.recognitionFailed("Invalid endpoint URL.")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("model", model)
        appendField("language", String(locale.identifier.prefix(2)))
        appendField("response_format", "json")

        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "status \(httpResponse.statusCode)"
            throw STTError.recognitionFailed(detail)
        }

        struct TranscriptionResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    // MARK: - Silence Timer (DispatchSource — immune to App Nap)

    private func resetSilenceTimer() {
        cancelSilenceTimer()
        let interval = hasDetectedSound ? silenceTimeout : initialSpeechTimeout
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                Log.stt("[STT-Whisper] Silence timeout — auto-stopping recording")
                self.stopListening()
            }
        }
        silenceTimerSource = timer
        timer.resume()
    }

    private func cancelSilenceTimer() {
        silenceTimerSource?.cancel()
        silenceTimerSource = nil
    }

    // MARK: - Cleanup

    private func cleanupAudioFile() {
        if let url = currentAudioURL {
            try? FileManager.default.removeItem(at: url)
            currentAudioURL = nil
        }
    }

    private func tearDown() {
        cancelSilenceTimer()
        audioCapture.stop()
        cleanupAudioFile()
        recordingTask?.cancel()
        recordingTask = nil
        isListening = false
        hasDetectedSound = false
    }
}

// MARK: - WhisperAudioCapture

/// Records microphone input to a WAV file. Reports RMS for silence detection.
private final class WhisperAudioCapture: @unchecked Sendable {

    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    var onStop: (() -> Void)?

    func startRecording(onRMS: @escaping @Sendable (Float) -> Void) throws -> URL {
        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            throw STTError.audioEngineError("No valid audio input format available.")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let file = try AVAudioFile(
            forWriting: tempURL,
            settings: recordingFormat.settings,
            commonFormat: recordingFormat.commonFormat,
            interleaved: recordingFormat.isInterleaved
        )
        self.outputFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            try? file.write(from: buffer)
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameCount { sum += channelData[i] * channelData[i] }
                let rms = sqrtf(sum / Float(max(frameCount, 1)))
                onRMS(rms)
            }
        }

        engine.prepare()
        try engine.start()
        return tempURL
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        outputFile = nil
        onStop?()
        onStop = nil
    }
}
