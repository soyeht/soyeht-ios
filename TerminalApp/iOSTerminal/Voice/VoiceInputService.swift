import AVFoundation
import Speech

@available(iOS 26, *)
final class VoiceInputService {
    static let shared = VoiceInputService()

    weak var delegate: VoiceInputDelegate?

    private var speechAnalyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var recordingStartTime: Date?

    private(set) var currentTranscription = ""
    private(set) var isListening = false
    private var accumulatedText = ""

    private init() {}

    // MARK: - Public API

    func startListening() async throws {
        guard !isListening else { return }

        // 1. Configure audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true)

        // 2. Check audio input
        guard session.isInputAvailable else {
            throw VoiceInputError.noAudioInput
        }

        // 3. Check SpeechTranscriber availability
        guard await SpeechTranscriber.isAvailable else {
            throw VoiceInputError.speechUnavailable
        }

        // 4. Resolve locale
        let language = TerminalPreferences.shared.voiceLanguage
        let locale: Locale
        if language != "auto",
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            locale = supported
        } else if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            locale = supported
        } else {
            throw VoiceInputError.languageNotSupported
        }

        // 5. Create transcriber
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // 6. Ensure assets are installed
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // 7. Get mic format and analyzer-compatible format
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)

        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw VoiceInputError.noAudioInput
        }

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: micFormat
        ) else {
            throw VoiceInputError.assetsNotReady
        }

        // 8. Create audio converter (mic → analyzer format)
        let converter: AVAudioConverter?
        if micFormat != targetFormat {
            converter = AVAudioConverter(from: micFormat, to: targetFormat)
        } else {
            converter = nil // formats match, no conversion needed
        }

        // 9. Create input stream and analyzer
        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Store state
        self.speechAnalyzer = analyzer
        self.transcriber = transcriber
        self.audioEngine = engine
        self.audioConverter = converter
        self.analyzerFormat = targetFormat
        self.inputContinuation = continuation
        self.currentTranscription = ""
        self.accumulatedText = ""
        self.recordingStartTime = Date()

        // 10. Install tap in mic's NATIVE format, convert before yielding
        let capturedTargetFormat = targetFormat
        let capturedConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // RMS for waveform visualization
            self.processAudioBuffer(buffer)

            // Convert to analyzer format if needed, then yield
            if let conv = capturedConverter {
                let ratio = capturedTargetFormat.sampleRate / micFormat.sampleRate
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard frameCount > 0,
                      let converted = AVAudioPCMBuffer(pcmFormat: capturedTargetFormat, frameCapacity: frameCount) else { return }

                var error: NSError?
                conv.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil {
                    self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
                }
            } else {
                // Formats match — yield directly
                self.inputContinuation?.yield(AnalyzerInput(buffer: buffer))
            }
        }

        // 11. Start engine
        try engine.start()
        isListening = true

        // 12. Start analysis in background
        analysisTask = Task { [weak self] in
            do {
                _ = try await analyzer.analyzeSequence(inputSequence)
            } catch {
                guard !(error is CancellationError) else { return }
                await MainActor.run {
                    self?.delegate?.voiceInputDidFail(error.localizedDescription)
                }
            }
        }

        // 13. Read transcription results — accumulate final segments
        transcriptionTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.isListening else { break }
                    let segment = String(result.text.characters)
                    await MainActor.run {
                        if result.isFinal {
                            if self.accumulatedText.isEmpty {
                                self.accumulatedText = segment
                            } else {
                                self.accumulatedText += " " + segment
                            }
                            self.currentTranscription = self.accumulatedText
                        } else {
                            // Show accumulated + in-progress partial
                            if self.accumulatedText.isEmpty {
                                self.currentTranscription = segment
                            } else {
                                self.currentTranscription = self.accumulatedText + " " + segment
                            }
                        }
                        self.delegate?.voiceInputDidUpdateTranscription(self.currentTranscription)
                    }
                }
            } catch {
                // Analysis cancelled or finished — expected
            }
        }
    }

    func stopListening() async -> String {
        guard isListening else { return currentTranscription }
        isListening = false

        // Stop audio capture
        inputContinuation?.finish()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // Finalize analysis — wait for pending results
        if let analyzer = speechAnalyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Wait for transcription task to finish consuming results
        await transcriptionTask?.value

        let finalText = currentTranscription
        cleanup()
        return finalText
    }

    func cancelListening() async {
        guard isListening else { return }
        isListening = false

        // Stop audio capture
        inputContinuation?.finish()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // Cancel analysis immediately
        if let analyzer = speechAnalyzer {
            await analyzer.cancelAndFinishNow()
        }

        analysisTask?.cancel()
        transcriptionTask?.cancel()

        currentTranscription = ""
        cleanup()
    }

    var elapsedTime: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Audio Level

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        let level = max(0, min(1, rms * 5))

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.voiceInputDidUpdateAudioLevel(level)
        }
    }

    // MARK: - Private

    private func cleanup() {
        analysisTask = nil
        transcriptionTask = nil
        inputContinuation = nil
        audioEngine = nil
        audioConverter = nil
        analyzerFormat = nil
        speechAnalyzer = nil
        transcriber = nil
        accumulatedText = ""
        recordingStartTime = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Errors

enum VoiceInputError: LocalizedError {
    case noAudioInput
    case speechUnavailable
    case languageNotSupported
    case assetsNotReady

    var errorDescription: String? {
        switch self {
        case .noAudioInput: return "No audio input available"
        case .speechUnavailable: return "Speech recognition is not available on this device"
        case .languageNotSupported: return "Language not supported for speech recognition"
        case .assetsNotReady: return "Speech recognition assets not ready"
        }
    }
}
