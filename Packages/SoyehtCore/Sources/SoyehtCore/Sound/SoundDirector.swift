import AVFoundation
import Foundation

/// Plays the two branded audio assets for onboarding milestones (research R16).
///
/// - `casaCriada.caf` — 440Hz + harmonics, ≤0.5s, peak −12dBFS.
/// - `moradorPareado.caf` — variant of casaCriada with +5 semitone pitch shift.
///
/// Respects `AVAudioSession.secondaryAudioShouldBeSilencedHint` on iOS and the
/// system volume. Silently no-ops when the asset is absent (e.g., simulator tests).
public final class SoundDirector: @unchecked Sendable {
    public enum Sound {
        /// Played when `POST /bootstrap/initialize` returns (house created).
        case casaCriada
        /// Played when the first morador pairing completes.
        case moradorPareado
    }

    private var players: [Sound: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "com.soyeht.sound-director")

    public static let shared = SoundDirector()

    public init() { preload() }

    /// Plays the named sound if system audio state permits.
    public func play(_ sound: Sound) {
        queue.async { self._play(sound) }
    }

    // MARK: - Private

    private func preload() {
        queue.async { [self] in
            for sound in [Sound.casaCriada, Sound.moradorPareado] {
                guard let url = Self.url(for: sound),
                      let player = try? AVAudioPlayer(contentsOf: url) else { continue }
                player.prepareToPlay()
                players[sound] = player
            }
        }
    }

    private func _play(_ sound: Sound) {
        guard !shouldSilence else { return }
        guard let player = players[sound] else { return }
        if player.isPlaying { player.stop(); player.currentTime = 0 }
        player.play()
    }

    /// Whether system audio policy requires silence.
    private var shouldSilence: Bool {
        #if os(iOS)
        return AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        #else
        return false
        #endif
    }

    private static func url(for sound: Sound) -> URL? {
        let name: String
        switch sound {
        case .casaCriada: name = "casa-criada"
        case .moradorPareado: name = "morador-pareado"
        }
        return Bundle.module.url(forResource: name, withExtension: "caf")
    }
}
