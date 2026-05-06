import Foundation
import AVFoundation
import Speech

@MainActor
protocol MacVoiceInputServiceDelegate: AnyObject {
    func macVoiceInputDidUpdateStatus(_ message: String)
    func macVoiceInputDidUpdateTranscription(_ text: String)
    func macVoiceInputDidUpdateAudioLevel(_ level: Float)
    func macVoiceInputDidFail(_ message: String)
}

enum MacVoiceInputLanguage: String, CaseIterable {
    case system
    case portugueseBrazil = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case spanishSpain = "es-ES"
    case spanishMexico = "es-MX"
    case frenchFrance = "fr-FR"
    case germanGermany = "de-DE"
    case italianItaly = "it-IT"
    case japaneseJapan = "ja-JP"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }

    var menuTitle: String {
        switch self {
        case .system:
            return String(localized: "voice.mac.language.system", defaultValue: "System Default")
        default:
            return Locale.current.localizedString(forIdentifier: rawValue) ?? rawValue
        }
    }
}

enum MacVoiceInputPreferences {
    static let didChangeNotification = Notification.Name("SoyehtVoiceInputPreferencesDidChange")

    private static let languageKey = "com.soyeht.mac.voiceInput.language"

    static var selectedLanguage: MacVoiceInputLanguage {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: languageKey),
                  let language = MacVoiceInputLanguage(rawValue: rawValue) else {
                return .system
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var selectedLocale: Locale {
        if let identifier = selectedLanguage.localeIdentifier {
            return Locale(identifier: identifier)
        }
        return Locale.current
    }
}

enum MacVoiceInputLog {
    private static let lock = NSLock()
    private static let url = URL(fileURLWithPath: "/tmp/soyeht-voice-input.log")

    static func reset() {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        appendLocked("---- voice input session started ----")
        #endif
    }

    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        appendLocked(message())
        #endif
    }

    private static func appendLocked(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [pid \(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

@available(macOS 26.0, *)
final class MacVoiceInputService {
    weak var delegate: MacVoiceInputServiceDelegate?

    private var speechAnalyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var bufferConverter: MacVoiceBufferConverter?
    private var lastAudioLevelLogAt = Date.distantPast
    private var didLogFirstAudioBuffer = false

    private(set) var isListening = false
    private(set) var currentTranscription = ""
    private var finalizedText = ""

    func startListening() async throws {
        guard !isListening else { return }

        MacVoiceInputLog.write("service.startListening entered")
        await notifyStatus(String(localized: "voice.mac.status.permission", defaultValue: "Checking microphone permission..."))
        MacVoiceInputLog.write("microphone authorization before request: \(Self.describe(AVCaptureDevice.authorizationStatus(for: .audio)))")

        guard await Self.requestMicrophoneAccess() else {
            MacVoiceInputLog.write("microphone access denied")
            throw MacVoiceInputError.microphoneDenied
        }

        await notifyStatus(String(localized: "voice.mac.status.microphoneReady", defaultValue: "Microphone authorized"))
        MacVoiceInputLog.write("microphone access authorized")
        MacVoiceInputLog.write("SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")

        guard SpeechTranscriber.isAvailable else {
            throw MacVoiceInputError.speechUnavailable
        }

        await notifyStatus(String(localized: "voice.mac.status.language", defaultValue: "Checking speech language..."))
        let requestedLocale = MacVoiceInputPreferences.selectedLocale
        MacVoiceInputLog.write("Locale.current=\(Locale.current.identifier)")
        MacVoiceInputLog.write("voice language preference=\(MacVoiceInputPreferences.selectedLanguage.rawValue), requestedLocale=\(requestedLocale.identifier)")

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            MacVoiceInputLog.write("no supported locale for requestedLocale=\(requestedLocale.identifier)")
            throw MacVoiceInputError.languageNotSupported
        }

        MacVoiceInputLog.write("selected speech locale=\(locale.identifier)")
        await notifyStatus(String(localized: "voice.mac.status.model", defaultValue: "Preparing speech model..."))

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            MacVoiceInputLog.write("speech asset installation request returned; downloading")
            try await request.downloadAndInstall()
            MacVoiceInputLog.write("speech assets installed")
        } else {
            MacVoiceInputLog.write("speech assets already available")
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        MacVoiceInputLog.write("mic format sampleRate=\(micFormat.sampleRate), channels=\(micFormat.channelCount), commonFormat=\(micFormat.commonFormat.rawValue), interleaved=\(micFormat.isInterleaved)")

        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            MacVoiceInputLog.write("invalid microphone format")
            throw MacVoiceInputError.noAudioInput
        }

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: micFormat
        ) else {
            MacVoiceInputLog.write("no target audio format available for speech analyzer")
            throw MacVoiceInputError.assetsNotReady
        }

        MacVoiceInputLog.write("target format sampleRate=\(targetFormat.sampleRate), channels=\(targetFormat.channelCount), commonFormat=\(targetFormat.commonFormat.rawValue), interleaved=\(targetFormat.isInterleaved)")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let converter = MacVoiceBufferConverter()

        speechAnalyzer = analyzer
        self.transcriber = transcriber
        audioEngine = engine
        inputContinuation = continuation
        bufferConverter = converter
        currentTranscription = ""
        finalizedText = ""
        isListening = true
        lastAudioLevelLogAt = .distantPast
        didLogFirstAudioBuffer = false

        transcriptionTask = Task { [weak self] in
            MacVoiceInputLog.write("transcriber results task started")
            do {
                for try await result in transcriber.results {
                    guard let self, self.isListening else { break }
                    self.handleTranscriptionResult(result)
                }
                MacVoiceInputLog.write("transcriber results task finished normally")
            } catch {
                guard !(error is CancellationError) else { return }
                MacVoiceInputLog.write("transcriber results task failed: \(error.localizedDescription)")
                await self?.notifyFailure(error.localizedDescription)
            }
        }

        do {
            await notifyStatus(String(localized: "voice.mac.status.analyzer", defaultValue: "Starting speech analyzer..."))
            try await analyzer.prepareToAnalyze(in: targetFormat)
            MacVoiceInputLog.write("speech analyzer prepared")
            try await analyzer.start(inputSequence: inputSequence)
            MacVoiceInputLog.write("speech analyzer started")

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                guard let self else { return }
                self.publishAudioLevel(from: buffer)

                do {
                    let converted = try converter.convert(buffer, to: targetFormat)
                    continuation.yield(AnalyzerInput(buffer: converted))
                } catch {
                    Task { await self.notifyFailure(error.localizedDescription) }
                }
            }
            MacVoiceInputLog.write("audio tap installed")

            engine.prepare()
            try engine.start()
            MacVoiceInputLog.write("audio engine started")
            await notifyStatus(String(localized: "voice.mac.status.listening", defaultValue: "Listening..."))
        } catch {
            MacVoiceInputLog.write("service.startListening failed: \(error.localizedDescription)")
            isListening = false
            await cancelListening()
            throw error
        }
    }

    func stopListening() async -> String {
        guard isListening else { return currentTranscription }

        MacVoiceInputLog.write("service.stopListening entered; currentTranscriptionLength=\(currentTranscription.count)")
        inputContinuation?.finish()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        MacVoiceInputLog.write("audio input stopped")

        if let analyzer = speechAnalyzer {
            MacVoiceInputLog.write("finalizing analyzer through end of input")
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            MacVoiceInputLog.write("analyzer finalized")
        }

        await transcriptionTask?.value

        isListening = false
        let finalText = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        MacVoiceInputLog.write("service.stopListening returning finalTextLength=\(finalText.count), finalText='\(Self.preview(finalText))'")
        cleanup()
        return finalText
    }

    func cancelListening() async {
        guard isListening || audioEngine != nil || speechAnalyzer != nil else {
            cleanup()
            return
        }
        MacVoiceInputLog.write("service.cancelListening entered")
        isListening = false

        inputContinuation?.finish()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        if let analyzer = speechAnalyzer {
            await analyzer.cancelAndFinishNow()
        }

        transcriptionTask?.cancel()
        currentTranscription = ""
        finalizedText = ""
        cleanup()
        MacVoiceInputLog.write("service.cancelListening finished")
    }

    private func handleTranscriptionResult(_ result: SpeechTranscriber.Result) {
        let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        MacVoiceInputLog.write("transcriber result isFinal=\(result.isFinal), segmentLength=\(segment.count), segment='\(Self.preview(segment))'")
        if result.isFinal {
            guard !segment.isEmpty else { return }
            finalizedText = finalizedText.isEmpty ? segment : finalizedText + " " + segment
            currentTranscription = finalizedText
        } else {
            currentTranscription = finalizedText.isEmpty ? segment : finalizedText + " " + segment
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.macVoiceInputDidUpdateTranscription(self.currentTranscription)
        }
    }

    private func publishAudioLevel(from buffer: AVAudioPCMBuffer) {
        let level = Self.audioLevel(from: buffer)
        let now = Date()
        if !didLogFirstAudioBuffer || now.timeIntervalSince(lastAudioLevelLogAt) >= 0.75 {
            didLogFirstAudioBuffer = true
            lastAudioLevelLogAt = now
            MacVoiceInputLog.write("audio buffer frameLength=\(buffer.frameLength), level=\(String(format: "%.3f", level))")
        }
        Task { @MainActor [weak self] in
            self?.delegate?.macVoiceInputDidUpdateAudioLevel(level)
        }
    }

    @MainActor
    private func notifyStatus(_ message: String) {
        MacVoiceInputLog.write("status: \(message)")
        delegate?.macVoiceInputDidUpdateStatus(message)
    }

    @MainActor
    private func notifyFailure(_ message: String) {
        MacVoiceInputLog.write("failure: \(message)")
        delegate?.macVoiceInputDidFail(message)
    }

    private func cleanup() {
        transcriptionTask = nil
        inputContinuation = nil
        audioEngine = nil
        bufferConverter = nil
        speechAnalyzer = nil
        transcriber = nil
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            MacVoiceInputLog.write("microphone authorization after prompt: \(allowed)")
            return allowed
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func audioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let channelCount = max(1, Int(buffer.format.channelCount))
        var total: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var sum: Float = 0
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
            total += sqrt(sum / Float(frameLength))
        }

        let average = total / Float(channelCount)
        return max(0, min(1, average * 5))
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }

    private static func preview(_ text: String) -> String {
        String(text.prefix(160)).replacingOccurrences(of: "\n", with: "\\n")
    }
}

@available(macOS 26.0, *)
private final class MacVoiceBufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.inputFormat != inputFormat || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw MacVoiceInputError.conversionFailed
        }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else {
            throw MacVoiceInputError.conversionFailed
        }

        var processed = false
        var nsError: NSError?
        let status = converter.convert(to: converted, error: &nsError) { _, inputStatus in
            defer { processed = true }
            inputStatus.pointee = processed ? .noDataNow : .haveData
            return processed ? nil : buffer
        }

        guard status != .error else {
            throw nsError ?? MacVoiceInputError.conversionFailed
        }

        return converted
    }
}

enum MacVoiceInputError: LocalizedError {
    case microphoneDenied
    case noAudioInput
    case speechUnavailable
    case languageNotSupported
    case assetsNotReady
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return String(localized: "voice.mac.error.microphoneDenied", defaultValue: "Microphone access is disabled")
        case .noAudioInput:
            return String(localized: "voice.mac.error.noAudioInput", defaultValue: "No microphone input is available")
        case .speechUnavailable:
            return String(localized: "voice.mac.error.speechUnavailable", defaultValue: "Speech transcription is not available on this Mac")
        case .languageNotSupported:
            return String(localized: "voice.mac.error.languageNotSupported", defaultValue: "Current language is not supported")
        case .assetsNotReady:
            return String(localized: "voice.mac.error.assetsNotReady", defaultValue: "Speech model is not ready")
        case .conversionFailed:
            return String(localized: "voice.mac.error.conversionFailed", defaultValue: "Audio conversion failed")
        }
    }
}
