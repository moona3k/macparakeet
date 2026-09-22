import Foundation

public enum SettingsHotkeyConflictMessage {
    public static func disabled(conflictingWith rowName: String, trigger: HotkeyTrigger) -> String {
        "Disabled — conflicts with \(rowName) (\(trigger.formattedLabel))."
    }

    public static func blocked(conflictingWith rowName: String, trigger: HotkeyTrigger) -> String {
        "Conflicts with \(rowName) (\(trigger.formattedLabel))."
    }
}

public enum SettingsDictationHotkeyConflictPolicy {
    public static func validation(
        candidate: HotkeyTrigger,
        peer: HotkeyTrigger,
        peerName: String
    ) -> HotkeyTrigger.ValidationResult? {
        guard
            let conflict = HotkeyConflictPolicy.dictationPeerConflict(
                candidate: candidate,
                peer: peer,
                peerName: peerName
            )
        else {
            return nil
        }
        return .blocked(
            SettingsHotkeyConflictMessage.blocked(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            ))
    }

    public static func existingConflictMessage(
        trigger: HotkeyTrigger,
        peer: HotkeyTrigger,
        peerName: String,
        disablesTrigger: Bool
    ) -> String? {
        guard
            let conflict = HotkeyConflictPolicy.dictationPeerConflict(
                candidate: trigger,
                peer: peer,
                peerName: peerName
            )
        else {
            return nil
        }
        if disablesTrigger {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            )
        }
        return SettingsHotkeyConflictMessage.blocked(
            conflictingWith: conflict.name,
            trigger: conflict.trigger
        )
    }
}

public enum HotkeyConflictPolicy {
    public enum Surface: Equatable, Sendable {
        case handsFreeDictation
        case pushToTalk
        case meetingRecording
        case fileTranscription
        case youtubeTranscription
    }

    public struct Candidate: Equatable, Sendable {
        public let trigger: HotkeyTrigger
        public let mode: HotkeyTrigger.ConflictMode

        public init(
            _ trigger: HotkeyTrigger,
            mode: HotkeyTrigger.ConflictMode = .exclusive
        ) {
            self.trigger = trigger
            self.mode = mode
        }
    }

    public struct NamedCandidate: Sendable {
        public let name: String
        public let trigger: HotkeyTrigger
        public let mode: HotkeyTrigger.ConflictMode

        public init(
            name: String,
            trigger: HotkeyTrigger,
            mode: HotkeyTrigger.ConflictMode = .exclusive
        ) {
            self.name = name
            self.trigger = trigger
            self.mode = mode
        }
    }

    public struct Conflict: Equatable, Sendable {
        public let name: String
        public let trigger: HotkeyTrigger

        public init(name: String, trigger: HotkeyTrigger) {
            self.name = name
            self.trigger = trigger
        }
    }

    public struct SettingsSnapshot: Sendable {
        public let handsFree: HotkeyTrigger
        public let pushToTalk: HotkeyTrigger
        public let meeting: HotkeyTrigger
        public let fileTranscription: HotkeyTrigger
        public let youtubeTranscription: HotkeyTrigger
        public let transformHotkeys: [Prompt]
        public let meetingRecordingEnabled: Bool

        public init(
            handsFree: HotkeyTrigger,
            pushToTalk: HotkeyTrigger,
            meeting: HotkeyTrigger,
            fileTranscription: HotkeyTrigger,
            youtubeTranscription: HotkeyTrigger,
            transformHotkeys: [Prompt],
            meetingRecordingEnabled: Bool
        ) {
            self.handsFree = handsFree
            self.pushToTalk = pushToTalk
            self.meeting = meeting
            self.fileTranscription = fileTranscription
            self.youtubeTranscription = youtubeTranscription
            self.transformHotkeys = transformHotkeys
            self.meetingRecordingEnabled = meetingRecordingEnabled
        }
    }

    public static func settingsValidation(
        candidate: HotkeyTrigger,
        surface: Surface,
        snapshot: SettingsSnapshot
    ) -> HotkeyTrigger.ValidationResult {
        guard !candidate.isDisabled else { return .allowed }
        guard
            let conflict = settingsConflict(
                for: candidate,
                surface: surface,
                snapshot: snapshot
            )
        else {
            return .allowed
        }
        return .blocked(
            SettingsHotkeyConflictMessage.blocked(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            ))
    }

    public static func settingsConflictMessage(
        for trigger: HotkeyTrigger,
        surface: Surface,
        snapshot: SettingsSnapshot
    ) -> String? {
        guard !trigger.isDisabled else { return nil }
        guard
            let conflict = settingsConflict(
                for: trigger,
                surface: surface,
                snapshot: snapshot
            )
        else {
            return nil
        }
        if existingConflictDisablesSurface(surface: surface, conflict: conflict) {
            return SettingsHotkeyConflictMessage.disabled(
                conflictingWith: conflict.name,
                trigger: conflict.trigger
            )
        }
        return SettingsHotkeyConflictMessage.blocked(
            conflictingWith: conflict.name,
            trigger: conflict.trigger
        )
    }

    public static func settingsConflict(
        for trigger: HotkeyTrigger,
        surface: Surface,
        snapshot: SettingsSnapshot
    ) -> Conflict? {
        switch surface {
        case .handsFreeDictation:
            if let conflict = dictationPeerConflict(
                candidate: trigger,
                peer: snapshot.pushToTalk,
                peerName: "push to talk"
            ) {
                return conflict
            }
            return firstConflict(
                for: trigger,
                selfMode: .bareModifierDictation,
                among: dictationPeerCandidates(snapshot: snapshot)
            )

        case .pushToTalk:
            if let conflict = dictationPeerConflict(
                candidate: trigger,
                peer: snapshot.handsFree,
                peerName: "hands-free mode"
            ) {
                return conflict
            }
            return firstConflict(
                for: trigger,
                selfMode: .bareModifierDictation,
                among: dictationPeerCandidates(snapshot: snapshot)
            )

        case .meetingRecording:
            return firstConflict(
                for: trigger,
                among: [
                    NamedCandidate(name: "hands-free mode", trigger: snapshot.handsFree, mode: .bareModifierDictation),
                    NamedCandidate(name: "push to talk", trigger: snapshot.pushToTalk, mode: .bareModifierDictation),
                    NamedCandidate(name: "file transcription", trigger: snapshot.fileTranscription),
                    NamedCandidate(name: "video URL transcription", trigger: snapshot.youtubeTranscription),
                ] + transformCandidates(snapshot.transformHotkeys)
            )

        case .fileTranscription:
            return firstConflict(
                for: trigger,
                among: transcriptionPeerCandidates(
                    otherTranscriptionName: "video URL transcription",
                    otherTranscriptionTrigger: snapshot.youtubeTranscription,
                    snapshot: snapshot
                )
            )

        case .youtubeTranscription:
            return firstConflict(
                for: trigger,
                among: transcriptionPeerCandidates(
                    otherTranscriptionName: "file transcription",
                    otherTranscriptionTrigger: snapshot.fileTranscription,
                    snapshot: snapshot
                )
            )
        }
    }

    public static func dictationPeerConflict(
        candidate: HotkeyTrigger,
        peer: HotkeyTrigger,
        peerName: String
    ) -> Conflict? {
        guard candidate.overlaps(with: peer) else { return nil }
        if HotkeyTrigger.isSharedDictationGesture(handsFree: candidate, pushToTalk: peer) {
            return nil
        }
        return Conflict(name: peerName, trigger: peer)
    }

    public static func firstConflict(
        for trigger: HotkeyTrigger,
        selfMode: HotkeyTrigger.ConflictMode = .exclusive,
        among candidates: [NamedCandidate]
    ) -> Conflict? {
        for candidate in candidates where !candidate.trigger.isDisabled {
            if trigger.conflicts(
                with: candidate.trigger,
                selfMode: selfMode,
                otherMode: candidate.mode
            ) {
                return Conflict(name: candidate.name, trigger: candidate.trigger)
            }
        }
        return nil
    }

    public static func conflictingTriggers(
        for trigger: HotkeyTrigger,
        among conflicts: [Candidate]
    ) -> [HotkeyTrigger] {
        conflicts.compactMap { conflict in
            guard !conflict.trigger.isDisabled,
                trigger.conflicts(with: conflict.trigger, otherMode: conflict.mode)
            else {
                return nil
            }
            return conflict.trigger
        }
    }

    private static func existingConflictDisablesSurface(
        surface: Surface,
        conflict: Conflict
    ) -> Bool {
        !(surface == .handsFreeDictation && conflict.name == "push to talk")
    }

    private static func dictationPeerCandidates(snapshot: SettingsSnapshot) -> [NamedCandidate] {
        var candidates: [NamedCandidate] = []
        if snapshot.meetingRecordingEnabled {
            candidates.append(NamedCandidate(name: "meeting recording", trigger: snapshot.meeting))
        }
        candidates.append(NamedCandidate(name: "file transcription", trigger: snapshot.fileTranscription))
        candidates.append(NamedCandidate(name: "video URL transcription", trigger: snapshot.youtubeTranscription))
        candidates.append(contentsOf: transformCandidates(snapshot.transformHotkeys))
        return candidates
    }

    private static func transcriptionPeerCandidates(
        otherTranscriptionName: String,
        otherTranscriptionTrigger: HotkeyTrigger,
        snapshot: SettingsSnapshot
    ) -> [NamedCandidate] {
        var candidates: [NamedCandidate] = [
            NamedCandidate(name: "hands-free mode", trigger: snapshot.handsFree, mode: .bareModifierDictation),
            NamedCandidate(name: "push to talk", trigger: snapshot.pushToTalk, mode: .bareModifierDictation),
        ]
        if snapshot.meetingRecordingEnabled {
            candidates.append(NamedCandidate(name: "meeting recording", trigger: snapshot.meeting))
        }
        candidates.append(NamedCandidate(name: otherTranscriptionName, trigger: otherTranscriptionTrigger))
        candidates.append(contentsOf: transformCandidates(snapshot.transformHotkeys))
        return candidates
    }

    private static func transformCandidates(_ transforms: [Prompt]) -> [NamedCandidate] {
        transforms.compactMap { transform in
            guard let shortcut = transform.shortcut else { return nil }
            return NamedCandidate(
                name: "Transform \(transform.name)",
                trigger: shortcut.hotkeyTrigger
            )
        }
    }
}

public enum TransformShortcutCollision: Equatable, Sendable {
    case missingModifier
    case macOSDeadKey
    case duplicateTransform(otherPromptID: UUID)
    case reservedHotkey(name: String)

    public var message: String {
        switch self {
        case .missingModifier:
            return "Shortcut must include a modifier key (\u{2303}, \u{2325}, \u{21E7}, or \u{2318})."
        case .macOSDeadKey:
            return "This shortcut produces a special character on Mac. Pick another combo."
        case .duplicateTransform:
            return "Another Transform already uses this shortcut."
        case .reservedHotkey(let name):
            return "This shortcut conflicts with \(name)."
        }
    }
}

public struct TransformShortcutCollisionChecker: Sendable {
    public init() {}

    public func check(
        candidate: KeyboardShortcut,
        existing: [UUID: KeyboardShortcut],
        excludingPromptID: UUID?,
        reservedHotkeys: [TransformShortcutReservedHotkey]
    ) -> TransformShortcutCollision? {
        guard candidate.hasModifier else { return .missingModifier }
        if candidate.isMacOSDeadKey { return .macOSDeadKey }

        for (otherID, other) in existing {
            if let exclude = excludingPromptID, exclude == otherID { continue }
            if matches(candidate, other) {
                return .duplicateTransform(otherPromptID: otherID)
            }
        }

        let candidateTrigger = candidate.hotkeyTrigger
        let conflictCandidates = reservedHotkeys.map {
            HotkeyConflictPolicy.NamedCandidate(
                name: $0.name,
                trigger: $0.trigger,
                mode: $0.conflictMode
            )
        }
        if let conflict = HotkeyConflictPolicy.firstConflict(
            for: candidateTrigger,
            among: conflictCandidates
        ) {
            return .reservedHotkey(name: conflict.name)
        }
        return nil
    }

    private func matches(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
}

public typealias TransformsHotkeyCollision = TransformShortcutCollision
public typealias TransformsHotkeyCollisionChecker = TransformShortcutCollisionChecker
