import Foundation

// MARK: - Voice Input State Machine

enum VoiceInputState: Equatable {
    case idle
    case recording
    case sending
    case error(String)
}

// MARK: - Voice Input Delegate

@MainActor
protocol VoiceInputDelegate: AnyObject {
    func voiceInputStateDidChange(_ state: VoiceInputState)
    func voiceInputDidUpdateTranscription(_ text: String)
    func voiceInputDidUpdateAudioLevel(_ level: Float)
    func voiceInputDidProduceText(_ text: String)
    func voiceInputDidFail(_ error: String)
}
