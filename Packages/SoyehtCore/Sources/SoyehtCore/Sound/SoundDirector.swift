import AVFoundation
import Foundation

/// Plays the two branded audio assets for onboarding milestones (research R16).
///
/// - `house-created.caf` — 440Hz + harmonics, ≤0.5s, peak −12dBFS.
/// - `resident-paired.caf` — variant of house-created with +5 semitone pitch shift.
///
/// Respects `AVAudioSession.secondaryAudioShouldBeSilencedHint` on iOS and the
/// system volume. Silently no-ops when the asset is absent (e.g., simulator tests).
public final class SoundDirector: @unchecked Sendable {
    public enum Sound {
        /// Played when `POST /bootstrap/initialize` returns (house created).
        case houseCreated
        /// Played when the first resident pairing completes.
        case residentPaired
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
            for sound in [Sound.houseCreated, Sound.residentPaired] {
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

    static func resourceURL(for sound: Sound) -> URL? {
        let name: String
        switch sound {
        case .houseCreated: name = "house-created"
        case .residentPaired: name = "resident-paired"
        }
        return Bundle.module.url(forResource: name, withExtension: "caf")
    }

    private static func url(for sound: Sound) -> URL? {
        resourceURL(for: sound)
    }
}
