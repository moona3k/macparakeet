import AppKit
import AVFoundation

/// Audio feedback system for MacParakeet.
/// Preloads custom sounds for zero-latency playback. Falls back to macOS system sounds
/// when custom assets aren't bundled yet. Respects macOS sound settings.
final class SoundManager {
    static let shared = SoundManager()

    private var players: [AppSound: AVAudioPlayer] = [:]
    private let volume: Float = 0.3

    private init() {
        preloadSounds()
    }

    /// Play a sound effect.
    func play(_ sound: AppSound) {
        // Respect macOS "Play sound effects" setting
        guard UserDefaults.standard.bool(forKey: "com.apple.sound.uiaudio.enabled") != false else { return }

        if let player = players[sound] {
            player.currentTime = 0
            player.play()
        } else if let systemName = sound.systemSoundFallback {
            NSSound(named: systemName)?.play()
        }
    }

    private func preloadSounds() {
        for sound in AppSound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "aif")
                    ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "wav") else {
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = volume
                player.prepareToPlay()
                players[sound] = player
            } catch {
                // Fall through to system sound fallback at play time
            }
        }
    }
}

/// Named sound effects for MacParakeet.
/// Custom assets will be bundled as .aif files. Until then, system sounds are used.
enum AppSound: String, CaseIterable {
    case recordStart = "record_start"
    case recordStop = "record_stop"
    case transcriptionComplete = "transcription_complete"
    case fileDropped = "file_dropped"
    case errorSoft = "error_soft"
    case copyClick = "copy_click"

    /// macOS system sound fallback when custom asset isn't bundled.
    var systemSoundFallback: NSSound.Name? {
        switch self {
        case .recordStart: return "Tink"
        case .recordStop: return "Pop"
        case .transcriptionComplete: return "Glass"
        case .fileDropped: return "Pop"
        case .errorSoft: return "Basso"
        case .copyClick: return "Tink"
        }
    }
}
