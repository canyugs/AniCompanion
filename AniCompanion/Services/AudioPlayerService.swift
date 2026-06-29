import Foundation
// @preconcurrency: AVFAudio's AVAudioConverterInputBlock is @Sendable but we capture a
// non-Sendable AVAudioPCMBuffer in it (safe here — the conversion is synchronous). This
// downgrades AVFAudio's Sendable diagnostics to keep the build warning-free under Swift 6.
@preconcurrency import AVFoundation
import Combine
import QuartzCore

// MARK: - Errors

enum AudioPlayerError: LocalizedError {
    case decodingFailed(String)
    case playbackFailed(String)
    case engineError(String)

    var errorDescription: String? {
        switch self {
        case .decodingFailed(let detail):
            return "Failed to decode audio data: \(detail)"
        case .playbackFailed(let detail):
            return "Audio playback failed: \(detail)"
        case .engineError(let detail):
            return "Audio engine error: \(detail)"
        }
    }
}

// MARK: - Implementation

@MainActor
final class AudioPlayerService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentAmplitude: Float = 0.0

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private var pcmStreamState: PCMStreamPlaybackState?

    /// Pre-computed RMS amplitude values for the current audio segment.
    private var amplitudeFrames: [Float] = []

    /// How many seconds each amplitude frame represents.
    private var amplitudeFrameDuration: TimeInterval = 0

    /// When playback started (CACurrentMediaTime).
    private var playbackStartTime: TimeInterval = 0

    /// Timer driving amplitude updates during playback.
    private var amplitudeTimer: Timer?

    private final class PCMStreamPlaybackState: @unchecked Sendable {
        var pendingBuffers: Int = 0
        var didFinishScheduling: Bool = false
        var didComplete: Bool = false
        var continuation: CheckedContinuation<Void, Error>?
    }

    // MARK: - Public Methods

    /// Decodes audio `Data` to PCM, plays it through the audio engine, and returns
    /// when playback completes. `currentAmplitude` is updated in real-time for lip sync.
    func playAudioData(_ data: Data) async throws {

        // Stop any existing playback (but keep the engine if possible).
        stopPlayback()

        // Decode compressed audio data to PCM buffer.
        let pcmBuffer = try decodeToPCM(data: data)

        // Pre-compute amplitude values for lip sync (avoids AVAudioEngine tap issues).
        let windowSize = 1024
        amplitudeFrames = Self.precomputeAmplitudes(from: pcmBuffer, windowSize: windowSize)
        amplitudeFrameDuration = Double(windowSize) / pcmBuffer.format.sampleRate

        let player = try await preparePlayer(format: pcmBuffer.format)

        isPlaying = true

        // Schedule the buffer and wait for playback to complete.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.playbackContinuation = continuation

            player.scheduleBuffer(pcmBuffer) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // Only resume if this continuation is still active (not cancelled by stop()).
                    if let cont = self.playbackContinuation {
                        self.playbackContinuation = nil
                        self.isPlaying = false
                        self.stopAmplitudeTimer()
                        cont.resume()
                    }
                }
            }

            do {
                try ObjC.catchException {
                    player.play()
                }
            } catch {
                self.playbackContinuation = nil
                self.tearDown()
                continuation.resume(throwing: AudioPlayerError.playbackFailed(error.localizedDescription))
                return
            }

            // Start amplitude timer for lip sync after playback begins.
            self.playbackStartTime = CACurrentMediaTime()
            self.startAmplitudeTimer()
        }
    }

    /// Plays signed 16-bit little-endian PCM chunks as they arrive.
    ///
    /// This is used by low-latency TTS providers that can return raw PCM directly.
    /// The player schedules each chunk onto `AVAudioPlayerNode` without waiting for
    /// the full utterance to download.
    func playPCM16Stream(
        _ chunks: AsyncThrowingStream<Data, Error>,
        sampleRate: Double,
        channels: Int
    ) async throws {
        stopPlayback()

        guard channels > 0 else {
            throw AudioPlayerError.playbackFailed("PCM stream must have at least one channel.")
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw AudioPlayerError.playbackFailed("Failed to create PCM stream format.")
        }

        let player = try await preparePlayer(format: format)
        let state = PCMStreamPlaybackState()
        pcmStreamState = state

        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        var pendingBytes = Data()
        var didStartPlayback = false

        amplitudeFrames = []
        amplitudeFrameDuration = Double(1024) / sampleRate
        isPlaying = true

        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                guard pcmStreamState === state else {
                    throw CancellationError()
                }

                pendingBytes.append(chunk)
                let playableByteCount = pendingBytes.count - (pendingBytes.count % bytesPerFrame)
                guard playableByteCount > 0 else { continue }

                let playableData = pendingBytes.subdata(in: 0..<playableByteCount)
                if playableByteCount == pendingBytes.count {
                    pendingBytes.removeAll(keepingCapacity: true)
                } else {
                    pendingBytes = Data(pendingBytes.dropFirst(playableByteCount))
                }

                let pcmBuffer = try Self.pcm16Buffer(from: playableData, format: format, channels: channels)
                amplitudeFrames.append(contentsOf: Self.precomputeAmplitudes(from: pcmBuffer, windowSize: 1024))

                state.pendingBuffers += 1
                player.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self, weak state] _ in
                    Task { @MainActor in
                        guard let self, let state, self.pcmStreamState === state else { return }
                        state.pendingBuffers -= 1
                        self.finishPCMStreamIfReady(state)
                    }
                }

                if !didStartPlayback {
                    do {
                        try ObjC.catchException {
                            player.play()
                        }
                    } catch {
                        state.pendingBuffers -= 1
                        throw AudioPlayerError.playbackFailed(error.localizedDescription)
                    }

                    didStartPlayback = true
                    playbackStartTime = CACurrentMediaTime()
                    startAmplitudeTimer()
                }
            }

            state.didFinishScheduling = true
            if state.pendingBuffers == 0 {
                finishPCMStreamIfReady(state)
                return
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.continuation = continuation
                self.finishPCMStreamIfReady(state)
            }
        } catch {
            clearPCMStreamState(state)
            throw error
        }
    }

    /// Stops playback immediately and tears down the engine completely.
    func stop() {
        // Capture and clear the continuation before tearDown to avoid double-resume.
        let continuation = playbackContinuation
        playbackContinuation = nil
        let pcmContinuation = pcmStreamState?.continuation
        pcmStreamState?.continuation = nil
        pcmStreamState = nil
        tearDown()
        continuation?.resume()
        pcmContinuation?.resume()
    }

    /// Stops the current playback but keeps the engine running for the next segment.
    private func stopPlayback() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        amplitudeFrames = []

        playerNode?.stop()

        let continuation = playbackContinuation
        playbackContinuation = nil
        let pcmContinuation = pcmStreamState?.continuation
        pcmStreamState?.continuation = nil
        pcmStreamState = nil
        continuation?.resume()
        pcmContinuation?.resume()

        isPlaying = false
        currentAmplitude = 0.0
    }

    // MARK: - Audio Decoding

    private func preparePlayer(format: AVAudioFormat) async throws -> AVAudioPlayerNode {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode

        if let existingEngine = audioEngine, let existingPlayer = playerNode, existingEngine.isRunning {
            engine = existingEngine
            player = existingPlayer
            // Reconnect with the new buffer's format in case it changed.
            engine.connect(player, to: engine.mainMixerNode, format: format)
        } else {
            // Tear down any stale engine before creating a new one.
            tearDown()

            engine = AVAudioEngine()
            player = AVAudioPlayerNode()

            engine.attach(player)

            // Connect player to the mixer. The engine handles format conversion internally.
            engine.connect(player, to: engine.mainMixerNode, format: format)

            self.audioEngine = engine
            self.playerNode = player

            engine.prepare()
            do {
                try engine.start()
            } catch {
                tearDown()
                throw AudioPlayerError.engineError(error.localizedDescription)
            }

            // Give the audio IO one cycle to stabilize before playing.
            try await Task.sleep(for: .milliseconds(50))
        }

        return player
    }

    /// Decodes audio `Data` into a PCM `AVAudioPCMBuffer`.
    private nonisolated func decodeToPCM(data: Data) throws -> AVAudioPCMBuffer {
        // Write data to a temporary file so AVAudioFile can read it.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(Self.fileExtension(for: data))

        do {
            try data.write(to: tempURL)
        } catch {
            throw AudioPlayerError.decodingFailed("Failed to write temporary audio file: \(error.localizedDescription)")
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Open the audio file.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: tempURL)
        } catch {
            throw AudioPlayerError.decodingFailed("Failed to read audio data: \(error.localizedDescription)")
        }

        // Read all frames into a PCM buffer.
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else {
            throw AudioPlayerError.decodingFailed("Audio file contains no frames.")
        }

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioFile.processingFormat.sampleRate,
            channels: audioFile.processingFormat.channelCount,
            interleaved: false
        ) else {
            throw AudioPlayerError.decodingFailed("Failed to create PCM output format.")
        }

        // If the source format matches our target, read directly.
        if audioFile.processingFormat.commonFormat == .pcmFormatFloat32 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                throw AudioPlayerError.decodingFailed("Failed to allocate PCM buffer.")
            }
            do {
                try audioFile.read(into: buffer)
            } catch {
                throw AudioPlayerError.decodingFailed("Failed to read audio frames: \(error.localizedDescription)")
            }
            return buffer
        }

        // Otherwise, convert to float32 PCM.
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: pcmFormat) else {
            throw AudioPlayerError.decodingFailed("Failed to create audio converter from \(audioFile.processingFormat) to \(pcmFormat).")
        }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw AudioPlayerError.decodingFailed("Failed to allocate output PCM buffer.")
        }

        // Read the source file into a temporary input buffer.
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw AudioPlayerError.decodingFailed("Failed to allocate input PCM buffer.")
        }

        do {
            try audioFile.read(into: inputBuffer)
        } catch {
            throw AudioPlayerError.decodingFailed("Failed to read audio frames for conversion: \(error.localizedDescription)")
        }

        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw AudioPlayerError.decodingFailed("Audio conversion failed: \(conversionError.localizedDescription)")
        }

        return outputBuffer
    }

    private nonisolated static func pcm16Buffer(
        from data: Data,
        format: AVAudioFormat,
        channels: Int
    ) throws -> AVAudioPCMBuffer {
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else {
            throw AudioPlayerError.decodingFailed("PCM stream chunk contains no complete frames.")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AudioPlayerError.decodingFailed("Failed to allocate PCM stream buffer.")
        }

        guard let channelData = buffer.floatChannelData else {
            throw AudioPlayerError.decodingFailed("PCM stream buffer has no channel data.")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let bytes = [UInt8](data)

        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let offset = (frame * channels + channel) * MemoryLayout<Int16>.size
                let rawValue = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let sample = Int16(bitPattern: rawValue)
                channelData[channel][frame] = Float(sample) / 32768.0
            }
        }

        return buffer
    }

    // MARK: - Amplitude Analysis (Pre-computed)

    /// Pre-computes RMS amplitude values from a PCM buffer in fixed-size windows.
    ///
    /// This approach avoids AVAudioEngine tap crashes caused by format mismatches
    /// when the engine converts between input format (e.g. 1ch 32kHz from TTS) and
    /// output format (e.g. 2ch 44.1kHz hardware). Instead, we compute amplitudes
    /// directly from the decoded PCM data and play them back via a timer.
    private nonisolated static func precomputeAmplitudes(from buffer: AVAudioPCMBuffer, windowSize: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        let samples = channelData[0]
        var amplitudes: [Float] = []
        amplitudes.reserveCapacity(frameLength / windowSize + 1)

        var offset = 0
        while offset < frameLength {
            let end = min(offset + windowSize, frameLength)
            var sumOfSquares: Float = 0.0

            for i in offset..<end {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }

            let count = Float(end - offset)
            let rms = sqrtf(sumOfSquares / count)

            // Scale RMS to a 0-1 range. Typical speech RMS is around 0.01-0.15.
            // A multiplier of 5 maps that to roughly 0.05-0.75, which works well for lip sync.
            let scaled = min(rms * 5.0, 1.0)
            amplitudes.append(scaled)

            offset += windowSize
        }

        return amplitudes
    }

    private nonisolated static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 4,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
            return "wav"
        }
        if bytes.count >= 4,
           bytes[0] == 0x4f, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            return "ogg"
        }
        if bytes.count >= 3,
           bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return "mp3"
        }
        if bytes.first == 0xff {
            return "mp3"
        }
        return "mp3"
    }

    /// Stops the amplitude timer without tearing down the engine.
    private func stopAmplitudeTimer() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        amplitudeFrames = []
        currentAmplitude = 0.0
    }

    /// Starts a timer that drives `currentAmplitude` from the pre-computed values.
    private func startAmplitudeTimer() {
        amplitudeTimer?.invalidate()
        // Update at ~30fps — sufficient for smooth lip sync animation.
        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickAmplitude()
            }
        }
    }

    /// Reads the current amplitude from pre-computed values based on elapsed playback time.
    private func tickAmplitude() {
        let elapsed = CACurrentMediaTime() - playbackStartTime
        guard amplitudeFrameDuration > 0 else { return }

        let index = Int(elapsed / amplitudeFrameDuration)
        if index < amplitudeFrames.count {
            currentAmplitude = amplitudeFrames[index]
        } else {
            currentAmplitude = 0
        }
    }

    private func finishPCMStreamIfReady(_ state: PCMStreamPlaybackState) {
        guard pcmStreamState === state,
              state.didFinishScheduling,
              state.pendingBuffers == 0,
              !state.didComplete else {
            return
        }

        state.didComplete = true
        let continuation = state.continuation
        state.continuation = nil
        pcmStreamState = nil
        isPlaying = false
        stopAmplitudeTimer()
        continuation?.resume()
    }

    private func clearPCMStreamState(_ state: PCMStreamPlaybackState) {
        guard pcmStreamState === state else { return }

        state.didComplete = true
        let continuation = state.continuation
        state.continuation = nil
        pcmStreamState = nil
        isPlaying = false
        stopAmplitudeTimer()
        continuation?.resume()
    }

    // MARK: - Cleanup

    private func tearDown() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        amplitudeFrames = []

        playerNode?.stop()
        playerNode = nil

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        audioEngine = nil

        isPlaying = false
        currentAmplitude = 0.0
    }
}
