import Foundation

enum TTSProvider: String, CaseIterable, Identifiable, Sendable {
    case miniMax
    case blueMagpie

    var id: String { rawValue }

    static let storageKey = "tts_provider"

    var displayName: String {
        switch self {
        case .miniMax: return "MiniMax"
        case .blueMagpie: return "BlueMagpie"
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
