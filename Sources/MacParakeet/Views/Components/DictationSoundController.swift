import AppKit
import AVFoundation
import Foundation
import Observation
import MacParakeetCore

@MainActor
protocol DictationCuePlaying: AnyObject {
    var isPlaying: Bool { get }
    func play(volume: Float) -> Bool
    func stop()
}

@MainActor
private final class AudioDictationCue: DictationCuePlaying {
    private let player: AVAudioPlayer

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
    }

    var isPlaying: Bool { player.isPlaying }
    func play(volume: Float) -> Bool {
        player.stop()
        player.currentTime = 0
        player.volume = volume
        return player.play()
    }
    func stop() { player.stop() }
}

@MainActor
private final class SystemDictationCue: DictationCuePlaying {
    private let sound: NSSound

    init?(cue: DictationSoundCue) {
        guard let copy = NSSound(named: NSSound.Name(cue.systemSoundName))?.copy() as? NSSound else { return nil }
        sound = copy
    }

    var isPlaying: Bool { sound.isPlaying }
    func play(volume: Float) -> Bool {
        sound.stop()
        sound.volume = volume
        return sound.play()
    }
    func stop() { sound.stop() }
}

/// Prepares dictation cues ahead of capture and keeps preview playback separate.
@MainActor
@Observable
final class DictationSoundController {
    enum PreviewResult: Equatable {
        case played, mutedBySystem, silent, captureCuePlaying, unavailable
    }

    private(set) var configurations: [DictationSoundCue: DictationSoundConfiguration] = [:]
    private(set) var warnings: [DictationSoundCue: String] = [:]
    private(set) var importing: Set<DictationSoundCue> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let library: DictationSoundLibrary
    @ObservationIgnored private let loadCustomData: @MainActor (String) async throws -> Data
    @ObservationIgnored private let makePlayer: @MainActor (Data) throws -> any DictationCuePlaying
    @ObservationIgnored private let makeSystemPlayer: @MainActor (DictationSoundCue) -> (any DictationCuePlaying)?
    @ObservationIgnored private let soundEffectsEnabled: @MainActor () -> Bool
    @ObservationIgnored private var systemPlayers: [DictationSoundCue: any DictationCuePlaying] = [:]
    @ObservationIgnored private var presetPlayers: [String: any DictationCuePlaying] = [:]
    @ObservationIgnored private var presetData: [String: Data] = [:]
    @ObservationIgnored private var customPlayers: [DictationSoundCue: any DictationCuePlaying] = [:]
    @ObservationIgnored private var customData: [DictationSoundCue: Data] = [:]
    @ObservationIgnored private var generations: [DictationSoundCue: Int] = [:]
    @ObservationIgnored private var activePlayer: (any DictationCuePlaying)?
    @ObservationIgnored private var previewPlayer: (any DictationCuePlaying)?

    init(
        defaults: UserDefaults,
        library: DictationSoundLibrary,
        loadCustomData: (@MainActor (String) async throws -> Data)? = nil,
        makePlayer: @escaping @MainActor (Data) throws -> any DictationCuePlaying = { try AudioDictationCue(data: $0) },
        makeSystemPlayer: @escaping @MainActor (DictationSoundCue) -> (any DictationCuePlaying)? = {
            SystemDictationCue(cue: $0)
        },
        resourceData: (String) -> Data? = { name in
            guard
                let url = Bundle.module.url(forResource: name, withExtension: "wav")
                    ?? Bundle.main.url(forResource: name, withExtension: "wav")
            else { return nil }
            return try? Data(contentsOf: url)
        },
        soundEffectsEnabled: @escaping @MainActor () -> Bool = { SoundManager.isSystemSoundEffectsEnabled }
    ) {
        self.defaults = defaults
        self.library = library
        self.loadCustomData = loadCustomData ?? { try await library.data(for: $0) }
        self.makePlayer = makePlayer
        self.makeSystemPlayer = makeSystemPlayer
        self.soundEffectsEnabled = soundEffectsEnabled
        for cue in DictationSoundCue.allCases {
            configurations[cue] = DictationSoundConfiguration.load(for: cue, defaults: defaults)
            systemPlayers[cue] = makeSystemPlayer(cue)
            for style in [DictationSoundStyle.handyPop, .handyMarimba] {
                guard let name = style.resourceName(for: cue), let data = resourceData(name),
                    let player = try? makePlayer(data)
                else { continue }
                presetData[name] = data
                presetPlayers[name] = player
            }
            updateWarning(for: cue)
        }
    }

    func configuration(for cue: DictationSoundCue) -> DictationSoundConfiguration {
        configurations[cue] ?? DictationSoundConfiguration()
    }

    /// Restore saved imports without overwriting a replacement made while loading.
    func prepareCustomSounds() async {
        for cue in DictationSoundCue.allCases {
            guard let fileName = configuration(for: cue).customFileName else { continue }
            let generation = generations[cue, default: 0]
            do {
                let data = try await loadCustomData(fileName)
                try Task.checkCancellation()
                guard generation == generations[cue, default: 0],
                    configuration(for: cue).customFileName == fileName
                else { continue }
                customPlayers[cue] = try makePlayer(data)
                customData[cue] = data
            } catch is CancellationError {
                return
            } catch {
                guard generation == generations[cue, default: 0] else { continue }
                customPlayers[cue] = nil
                customData[cue] = nil
            }
            updateWarning(for: cue)
        }
    }

    func setStyle(_ style: DictationSoundStyle, for cue: DictationSoundCue) {
        guard !importing.contains(cue) else { return }
        var value = configuration(for: cue)
        guard style != .custom || value.customFileName != nil else { return }
        value.style = style
        store(value, for: cue)
        updateWarning(for: cue)
        stopPreview()
    }

    func setVolume(_ volume: Double, for cue: DictationSoundCue) {
        var value = configuration(for: cue)
        value.volume = volume
        // A volume edit must not invalidate an in-flight asset restore.
        configurations[cue] = value.normalized
        value.save(for: cue, defaults: defaults)
    }

    func importSound(from source: URL, for cue: DictationSoundCue) async throws {
        guard !importing.contains(cue) else { return }
        importing.insert(cue)
        defer { importing.remove(cue) }
        let imported = try await library.importSound(from: source)
        let player: any DictationCuePlaying
        do {
            try Task.checkCancellation()
            player = try makePlayer(imported.data)
            try Task.checkCancellation()
        } catch {
            try? await library.remove(imported.fileName)
            throw error
        }
        let previous = configuration(for: cue).customFileName
        var value = configuration(for: cue)
        value.style = .custom
        value.customFileName = imported.fileName
        value.customDisplayName = imported.displayName
        customPlayers[cue]?.stop()
        customPlayers[cue] = player
        customData[cue] = imported.data
        store(value, for: cue)
        updateWarning(for: cue)
        stopPreview()
        await removeIfUnreferenced(previous)
    }

    func reset(_ cue: DictationSoundCue) async {
        guard !importing.contains(cue) else { return }
        let previous = configuration(for: cue).customFileName
        customPlayers[cue]?.stop()
        customPlayers[cue] = nil
        customData[cue] = nil
        store(DictationSoundConfiguration(), for: cue)
        updateWarning(for: cue)
        stopPreview()
        await removeIfUnreferenced(previous)
    }

    func play(_ cue: DictationSoundCue) {
        // A silent cue still ends the previous cue.
        stopPreview()
        activePlayer?.stop()
        activePlayer = nil
        let value = configuration(for: cue)
        guard soundEffectsEnabled(), value.style != .silent, value.volume > 0 else { return }
        let selected = selectedPlayer(for: cue)
        if let selected, selected.play(volume: Float(value.volume)) {
            activePlayer = selected
            updateWarning(for: cue)
            return
        }
        selected?.stop()
        // A prepared custom/preset player may still fail to start. Try the
        // already-prepared system cue once, without retrying that same player.
        if let fallback = systemPlayers[cue], selected !== fallback {
            if fallback.play(volume: Float(value.volume)) {
                activePlayer = fallback
                updateWarning(for: cue)
                if selected != nil {
                    warnings[cue] = "This sound could not be played. Using \(cue.systemSoundName) instead."
                }
                return
            }
            fallback.stop()
        }
        warnings[cue] = "This sound could not be played. Choose another sound."
    }

    func preview(_ cue: DictationSoundCue) -> PreviewResult {
        stopPreview()
        guard soundEffectsEnabled() else { return .mutedBySystem }
        let value = configuration(for: cue)
        guard value.style != .silent, value.volume > 0 else { return .silent }
        guard activePlayer?.isPlaying != true else { return .captureCuePlaying }
        let data: Data?
        if value.style == .custom {
            data = customData[cue]
        } else if let name = value.style.resourceName(for: cue) {
            data = presetData[name]
        } else {
            data = nil
        }
        // A private preview player never mutates the capture player's state.
        if let data { previewPlayer = try? makePlayer(data) }
        if previewPlayer == nil { previewPlayer = makeSystemPlayer(cue) }
        guard let previewPlayer else { return .unavailable }
        guard previewPlayer.play(volume: Float(value.volume)) else {
            stopPreview()
            return .unavailable
        }
        return .played
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
    }

    private func selectedPlayer(for cue: DictationSoundCue) -> (any DictationCuePlaying)? {
        let value = configuration(for: cue)
        if value.style == .custom { return customPlayers[cue] }
        if let name = value.style.resourceName(for: cue) { return presetPlayers[name] }
        return systemPlayers[cue]
    }

    private func store(_ value: DictationSoundConfiguration, for cue: DictationSoundCue) {
        if configuration(for: cue).customFileName != value.normalized.customFileName {
            generations[cue, default: 0] += 1
        }
        configurations[cue] = value.normalized
        value.save(for: cue, defaults: defaults)
    }

    private func updateWarning(for cue: DictationSoundCue) {
        let value = configuration(for: cue)
        if value.style == .custom && customPlayers[cue] == nil {
            warnings[cue] =
                "Custom sound unavailable. Using \(cue.systemSoundName); import the file again to restore it."
        } else if let name = value.style.resourceName(for: cue), presetPlayers[name] == nil {
            warnings[cue] = "This bundled sound is unavailable. Using \(cue.systemSoundName) instead."
        } else {
            warnings[cue] = nil
        }
    }

    private func removeIfUnreferenced(_ fileName: String?) async {
        guard let fileName,
            !configurations.values.contains(where: { $0.customFileName == fileName })
        else { return }
        // Cleanup failure must not roll back the new selection.
        try? await library.remove(fileName)
    }
}
