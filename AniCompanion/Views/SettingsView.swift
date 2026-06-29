import SwiftUI

// MARK: - SettingsView

/// A form-based settings panel presented as a sheet.
///
/// Allows the user to configure the agent backend connection, API keys, TTS voice,
/// and interface/character language. Settings are persisted via `AppState`'s
/// `@AppStorage` properties.
struct SettingsView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewAudioPlayer = AudioPlayerService()

    // Local copies for edit-then-save workflow.
    @State private var minimaxAPIKey: String = ""
    @State private var minimaxGroupID: String = ""
    @State private var backend: ChatBackend = .hermes
    /// Per-backend working copies (edit-then-save). Switching the picker swaps which
    /// backend's entry the fields show; nothing is persisted until Save.
    @State private var endpoints: [ChatBackend: String] = [:]
    @State private var apiKeys: [ChatBackend: String] = [:]
    @State private var ttsProvider: TTSProvider = .miniMax
    @State private var ttsVoiceID: String = "Chinese (Mandarin)_Crisp_Girl"
    @State private var ttsEnabled: Bool = true
    @State private var openAITTSAPIKey: String = ""
    @State private var openAITTSModel: String = "gpt-4o-mini-tts"
    @State private var openAITTSVoice: String = "coral"
    @State private var openAITTSInstructions: String = "Speak warmly and expressively, like a friendly anime companion."
    @State private var groqTTSAPIKey: String = ""
    @State private var groqTTSModel: String = "canopylabs/orpheus-v1-english"
    @State private var groqTTSVoice: String = "troy"
    @State private var language: AppLanguage = .english
    @State private var tier2Enabled: Bool = false
    @State private var tier2Endpoint: String = "http://127.0.0.1:9100"
    @State private var isVoicePreviewing = false
    @State private var voicePreviewError: String?
    @State private var voicePreviewTask: Task<Void, Never>?

    /// Shows the "restart to apply UI language" alert after a language change.
    @State private var showRestartAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header

            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // MARK: - Form Content

            ScrollView {
                VStack(spacing: 24) {

                    // MARK: Section 0: Connection

                    SettingsSection(title: "Connection", icon: "network") {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsField(label: "Agent backend") {
                                Picker("", selection: $backend) {
                                    ForEach(ChatBackend.allCases) { b in
                                        Text(b.displayName).tag(b)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                // No onChange needed: the fields bind to the selected backend's
                                // working copy, so switching the picker swaps them automatically.
                            }

                            SettingsField(label: "Endpoint") {
                                TextField(backend.defaultEndpoint, text: endpointBinding)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            }

                            SettingsField(label: "API Key") {
                                SecureField("API key (if required)", text: apiKeyBinding)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            }
                            Text(backend.configHint)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    // MARK: Section 1: API Keys

                    SettingsSection(title: "API Keys", icon: "key.fill") {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsField(label: "TTS Provider") {
                                Picker("", selection: $ttsProvider) {
                                    ForEach(TTSProvider.allCases) { provider in
                                        Text(provider.displayName).tag(provider)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }

                            switch ttsProvider {
                            case .miniMax:
                                SettingsField(label: "MiniMax API Key") {
                                    settingsTextField("eyJ...", text: $minimaxAPIKey, secure: true)
                                }

                                SettingsField(label: "MiniMax Group ID") {
                                    settingsTextField("Group ID", text: $minimaxGroupID)
                                }
                            case .openAI:
                                SettingsField(label: "OpenAI API Key") {
                                    settingsTextField("sk-...", text: $openAITTSAPIKey, secure: true)
                                }
                            case .groq:
                                SettingsField(label: "Groq API Key") {
                                    settingsTextField("gsk_...", text: $groqTTSAPIKey, secure: true)
                                }
                            }
                        }
                    }

                    // MARK: Section 2: Model Settings

                    SettingsSection(title: "Voice", icon: "speaker.wave.2.fill") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Enable TTS Voice", isOn: $ttsEnabled)
                                .toggleStyle(.switch)

                            switch ttsProvider {
                            case .miniMax:
                                SettingsField(label: "TTS Voice ID") {
                                    voiceSelector(
                                        placeholder: "Chinese (Mandarin)_Crisp_Girl",
                                        selection: $ttsVoiceID,
                                        options: miniMaxVoiceOptions
                                    )
                                }
                            case .openAI:
                                SettingsField(label: "OpenAI Model") {
                                    settingsTextField("gpt-4o-mini-tts", text: $openAITTSModel)
                                }

                                SettingsField(label: "OpenAI Voice") {
                                    voiceSelector(
                                        placeholder: "coral",
                                        selection: $openAITTSVoice,
                                        options: openAIVoiceOptions
                                    )
                                }

                                SettingsField(label: "Voice Instructions") {
                                    settingsTextField("Speak warmly and expressively...", text: $openAITTSInstructions)
                                }
                            case .groq:
                                SettingsField(label: "Groq Model") {
                                    settingsTextField("canopylabs/orpheus-v1-english", text: $groqTTSModel)
                                }

                                SettingsField(label: "Groq Voice") {
                                    voiceSelector(
                                        placeholder: "troy",
                                        selection: $groqTTSVoice,
                                        options: groqVoiceOptions(for: groqTTSModel)
                                    )
                                }
                            }

                            voicePreviewControls
                        }
                    }

                    // MARK: Section 3: Agent State (Tier-2)

                    SettingsSection(title: "Agent State", icon: "antenna.radiowaves.left.and.right") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Enable Tier-2 WS", isOn: $tier2Enabled)
                                .toggleStyle(.switch)

                            if tier2Enabled {
                                SettingsField(label: "Adapter Endpoint") {
                                    TextField("http://127.0.0.1:9100", text: $tier2Endpoint)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                }
                            }

                            Text("Connects to the OpenAB VTuber Adapter for real-time agent state, emotions, and ambient notifications.")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    // MARK: Section 4: Language

                    SettingsSection(title: "Language", icon: "globe") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: $language) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()

                            Text("Interface & character language")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            Divider()

            // MARK: - Action Buttons

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Button("Save") {
                    let languageChanged = (language != AppLanguage.current)
                    saveSettings()
                    if languageChanged {
                        showRestartAlert = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 760)
        .background(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)))
        .preferredColorScheme(.dark)
        .onAppear {
            loadSettings()
        }
        .onDisappear {
            stopVoicePreview()
        }
        .onChange(of: ttsProvider) { _, _ in
            stopVoicePreview()
            voicePreviewError = nil
        }
        .alert("Restart required", isPresented: $showRestartAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("Restart AniCompanion to apply the new interface language. (The character switches right away.)")
        }
    }

    // MARK: - Per-Backend Connection Bindings

    /// The endpoint field, bound to the selected backend's working copy.
    private var endpointBinding: Binding<String> {
        Binding(
            get: { endpoints[backend] ?? backend.defaultEndpoint },
            set: { endpoints[backend] = $0 }
        )
    }

    /// The API-key field, bound to the selected backend's working copy.
    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { apiKeys[backend] ?? "" },
            set: { apiKeys[backend] = $0 }
        )
    }

    private var voicePreviewControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if isVoicePreviewing {
                        stopVoicePreview()
                    } else {
                        startVoicePreview()
                    }
                } label: {
                    Label(
                        isVoicePreviewing ? "Stop Preview" : "Preview Voice",
                        systemImage: isVoicePreviewing ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!canPreviewVoice && !isVoicePreviewing)

                if isVoicePreviewing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !canPreviewVoice {
                Text(previewCredentialHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if let voicePreviewError {
                Text(voicePreviewError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canPreviewVoice: Bool {
        switch ttsProvider {
        case .miniMax:
            return !minimaxAPIKey.trimmed.isEmpty && !minimaxGroupID.trimmed.isEmpty
        case .openAI:
            return !openAITTSAPIKey.trimmed.isEmpty
        case .groq:
            return !groqTTSAPIKey.trimmed.isEmpty
        }
    }

    private var previewCredentialHint: String {
        switch ttsProvider {
        case .miniMax:
            return "Enter MiniMax API Key and Group ID to preview."
        case .openAI:
            return "Enter OpenAI API Key to preview."
        case .groq:
            return "Enter Groq API Key to preview."
        }
    }

    private var previewSampleText: String {
        switch language {
        case .english:
            return "Hi, I am Xiaoguang. This is a quick voice preview."
        case .traditionalChinese:
            return "嗨，我是小光。這是目前聲音的快速試聽。"
        }
    }

    @ViewBuilder
    private func settingsTextField(_ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        if secure {
            SecureField(placeholder, text: text)
                .settingsFieldChrome()
        } else {
            TextField(placeholder, text: text)
                .settingsFieldChrome()
        }
    }

    private func voiceSelector(
        placeholder: String,
        selection: Binding<String>,
        options: [TTSVoiceOption]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: selection) {
                ForEach(optionsIncludingCurrent(options, current: selection.wrappedValue)) { option in
                    Text(option.menuTitle).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            settingsTextField(placeholder, text: selection)
        }
    }

    private func optionsIncludingCurrent(_ options: [TTSVoiceOption], current: String) -> [TTSVoiceOption] {
        let current = current.trimmed
        guard !current.isEmpty, !options.contains(where: { $0.id == current }) else {
            return options
        }
        return [TTSVoiceOption(id: current, name: current, detail: "Custom")] + options
    }

    private var miniMaxVoiceOptions: [TTSVoiceOption] {
        [
            TTSVoiceOption(id: "Chinese (Mandarin)_Crisp_Girl", name: "Crisp Girl", detail: "Mandarin")
        ]
    }

    private var openAIVoiceOptions: [TTSVoiceOption] {
        [
            TTSVoiceOption(id: "coral", name: "Coral", detail: "Warm"),
            TTSVoiceOption(id: "marin", name: "Marin", detail: "Recommended"),
            TTSVoiceOption(id: "cedar", name: "Cedar", detail: "Recommended"),
            TTSVoiceOption(id: "nova", name: "Nova", detail: "Bright"),
            TTSVoiceOption(id: "shimmer", name: "Shimmer", detail: "Soft"),
            TTSVoiceOption(id: "sage", name: "Sage", detail: "Calm"),
            TTSVoiceOption(id: "alloy", name: "Alloy", detail: "Neutral"),
            TTSVoiceOption(id: "ash", name: "Ash", detail: "Clear"),
            TTSVoiceOption(id: "ballad", name: "Ballad", detail: "Expressive"),
            TTSVoiceOption(id: "echo", name: "Echo", detail: "Narration"),
            TTSVoiceOption(id: "fable", name: "Fable", detail: "Story"),
            TTSVoiceOption(id: "onyx", name: "Onyx", detail: "Deep"),
            TTSVoiceOption(id: "verse", name: "Verse", detail: "Expressive")
        ]
    }

    private func groqVoiceOptions(for model: String) -> [TTSVoiceOption] {
        if model.contains("arabic") {
            return [
                TTSVoiceOption(id: "noura", name: "Noura", detail: "Arabic, female"),
                TTSVoiceOption(id: "lulwa", name: "Lulwa", detail: "Arabic, female"),
                TTSVoiceOption(id: "aisha", name: "Aisha", detail: "Arabic, female"),
                TTSVoiceOption(id: "abdullah", name: "Abdullah", detail: "Arabic, male"),
                TTSVoiceOption(id: "fahad", name: "Fahad", detail: "Arabic, male"),
                TTSVoiceOption(id: "sultan", name: "Sultan", detail: "Arabic, male")
            ]
        }

        return [
            TTSVoiceOption(id: "hannah", name: "Hannah", detail: "Female"),
            TTSVoiceOption(id: "autumn", name: "Autumn", detail: "Female"),
            TTSVoiceOption(id: "diana", name: "Diana", detail: "Female"),
            TTSVoiceOption(id: "troy", name: "Troy", detail: "Male"),
            TTSVoiceOption(id: "austin", name: "Austin", detail: "Male"),
            TTSVoiceOption(id: "daniel", name: "Daniel", detail: "Male")
        ]
    }

    private func startVoicePreview() {
        guard canPreviewVoice else { return }

        voicePreviewTask?.cancel()
        previewAudioPlayer.stop()
        voicePreviewError = nil
        isVoicePreviewing = true

        let service = TTSService(
            provider: ttsProvider,
            miniMaxAPIKey: minimaxAPIKey,
            miniMaxGroupID: minimaxGroupID,
            miniMaxVoiceID: ttsVoiceID,
            openAIAPIKey: openAITTSAPIKey,
            openAIModel: openAITTSModel,
            openAIVoice: openAITTSVoice,
            openAIInstructions: openAITTSInstructions,
            groqAPIKey: groqTTSAPIKey,
            groqModel: groqTTSModel,
            groqVoice: groqTTSVoice
        )
        let sampleText = previewSampleText
        let player = previewAudioPlayer

        voicePreviewTask = Task { @MainActor in
            do {
                let stream = service.synthesize(text: sampleText, emotion: .happy)
                try await playPreviewStream(stream, using: player)
            } catch is CancellationError {
                // Stopping preview is user-driven and should not surface as an error.
            } catch {
                voicePreviewError = error.localizedDescription
            }

            if !Task.isCancelled {
                isVoicePreviewing = false
                voicePreviewTask = nil
            }
        }
    }

    private func stopVoicePreview() {
        voicePreviewTask?.cancel()
        voicePreviewTask = nil
        previewAudioPlayer.stop()
        isVoicePreviewing = false
    }

    @MainActor
    private func playPreviewStream(_ stream: TTSAudioStream, using player: AudioPlayerService) async throws {
        switch stream.format {
        case .encoded:
            var audioData = Data()
            for try await chunk in stream.chunks {
                try Task.checkCancellation()
                audioData.append(chunk)
            }
            if !audioData.isEmpty {
                try await player.playAudioData(audioData)
            }
        case let .pcm16(sampleRate, channels):
            try await player.playPCM16Stream(stream.chunks, sampleRate: sampleRate, channels: channels)
        }
    }

    // MARK: - Data Flow

    /// Load current settings from AppState into local state.
    private func loadSettings() {
        backend = ChatBackend.current
        // Seed every backend's working copy from its own saved connection.
        for b in ChatBackend.allCases {
            endpoints[b] = b.savedEndpoint()
            apiKeys[b] = b.savedAPIKey()
        }
        minimaxAPIKey = appState.minimaxAPIKey
        minimaxGroupID = appState.minimaxGroupID
        ttsProvider = TTSProvider.current
        ttsVoiceID = appState.ttsVoiceID
        ttsEnabled = appState.ttsEnabled
        openAITTSAPIKey = appState.openAITTSAPIKey
        openAITTSModel = appState.openAITTSModel
        openAITTSVoice = appState.openAITTSVoice
        openAITTSInstructions = appState.openAITTSInstructions
        groqTTSAPIKey = appState.groqTTSAPIKey
        groqTTSModel = appState.groqTTSModel
        groqTTSVoice = appState.groqTTSVoice
        language = AppLanguage.current
        tier2Enabled = appState.tier2Enabled
        tier2Endpoint = appState.tier2Endpoint
    }

    /// Write local state back to AppState for persistence, then reinitialize services.
    private func saveSettings() {
        appState.chatBackend = backend.rawValue
        // Persist each backend's own connection.
        for b in ChatBackend.allCases {
            b.saveConnection(
                endpoint: endpoints[b] ?? b.defaultEndpoint,
                apiKey: apiKeys[b] ?? ""
            )
        }
        appState.minimaxAPIKey = minimaxAPIKey
        appState.minimaxGroupID = minimaxGroupID
        appState.ttsProvider = ttsProvider.rawValue
        appState.ttsVoiceID = ttsVoiceID
        appState.ttsEnabled = ttsEnabled
        appState.openAITTSAPIKey = openAITTSAPIKey
        appState.openAITTSModel = openAITTSModel
        appState.openAITTSVoice = openAITTSVoice
        appState.openAITTSInstructions = openAITTSInstructions
        appState.groqTTSAPIKey = groqTTSAPIKey
        appState.groqTTSModel = groqTTSModel
        appState.groqTTSVoice = groqTTSVoice

        // Persist the language. The character/persona + STT pick it up immediately on
        // reinitialize; the SwiftUI interface needs `AppleLanguages` + a relaunch.
        appState.appLanguage = language.rawValue
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")

        // Apply TTS toggle immediately (no reinit needed).
        appState.conversationController?.ttsEnabled = ttsEnabled

        appState.tier2Enabled = tier2Enabled
        appState.tier2Endpoint = tier2Endpoint

        // Recreate services with updated settings.
        appState.reinitializeServices()
    }
}

// MARK: - Voice Options

private struct TTSVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String

    var menuTitle: String {
        "\(name) — \(id) · \(detail)"
    }
}

// MARK: - SettingsSection

/// A labeled section container with an icon and title.
private struct SettingsSection<Content: View>: View {

    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            // Section content
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsField

/// A labeled field within a settings section.
private struct SettingsField<Content: View>: View {

    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            content
        }
    }
}

private extension View {
    func settingsFieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
