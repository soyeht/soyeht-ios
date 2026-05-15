import AVFoundation
import Speech

enum VoicePermissionStatus {
    case granted
    case denied
    case notDetermined
    case restricted
}

final class VoicePermissionHelper {

    static func microphoneStatus() -> VoicePermissionStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func speechRecognitionStatus() -> VoicePermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func requestSpeechRecognitionAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func requestAllPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await requestMicrophoneAccess()
        let speech = await requestSpeechRecognitionAccess()
        return (mic, speech)
    }

    static func denialMessage() -> String? {
        let mic = microphoneStatus()
        let speech = speechRecognitionStatus()
        if mic == .denied || mic == .restricted {
            return String(localized: "voice.permission.microphoneDenied", comment: "Shown when the user denied or restricted microphone access — directs them to iOS Settings.")
        }
        if speech == .denied || speech == .restricted {
            return String(localized: "voice.permission.speechDenied", comment: "Shown when the user denied or restricted Speech Recognition — directs them to iOS Settings.")
        }
        return nil
    }
}
