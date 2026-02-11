import AppKit
import AVFoundation

/// Audio feedback system for MacParakeet.
/// Preloads custom sounds for zero-latency playback. Falls back to macOS system sounds
/// when custom assets aren't bundled yet. Respects macOS sound settings.
final class SoundManager {
    static let shared = SoundManager()
    private static let uiAudioEnabledKey = "com.apple.sound.uiaudio.enabled"

    private var players: [AppSound: AVAudioPlayer] = [:]
    private let volume: Float = 0.3

    private init() {
        preloadSounds()
    }

    /// Play a sound effect.
    func play(_ sound: AppSound) {
        // Respect macOS "Play sound effects" setting
        guard Self.isSystemSoundEffectsEnabled else { return }

        if let player = players[sound] {
            player.currentTime = 0
            player.play()
        } else if let systemName = sound.systemSoundFallback {
            NSSound(named: systemName)?.play()
        }
    }

    private static var isSystemSoundEffectsEnabled: Bool {
        if let value = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[uiAudioEnabledKey] as? Bool {
            return value
        }
        if let value = UserDefaults.standard.object(forKey: uiAudioEnabledKey) as? Bool {
            return value
        }
        // Default to enabled when the preference key is absent.
        return true
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
