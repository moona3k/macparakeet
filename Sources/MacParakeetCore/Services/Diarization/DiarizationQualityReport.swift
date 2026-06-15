import Foundation

public struct DiarizationQualityReport: Codable, Sendable, Equatable {
    public var transcriptionSourceType: Transcription.SourceType
    public var diarizedAudioSource: AudioSource?
    public var requestedSpeakerHint: SpeakerCountHint?
    public var detectedSpeakerCount: Int
    public var rawDiarizationSegmentCount: Int
    public var segmentsPerSpeaker: [String: Int]
    public var speakingTimeMsPerSpeaker: [String: Int]
    public var assignmentSummary: WordSpeakerAssignmentSummary
    public var warnings: [DiarizationQualityWarning]

    public init(
        transcriptionSourceType: Transcription.SourceType,
        diarizedAudioSource: AudioSource?,
        requestedSpeakerHint: SpeakerCountHint?,
        detectedSpeakerCount: Int,
        rawDiarizationSegmentCount: Int,
        segmentsPerSpeaker: [String: Int],
        speakingTimeMsPerSpeaker: [String: Int],
        assignmentSummary: WordSpeakerAssignmentSummary,
        warnings: [DiarizationQualityWarning]
    ) {
        self.transcriptionSourceType = transcriptionSourceType
        self.diarizedAudioSource = diarizedAudioSource
        self.requestedSpeakerHint = requestedSpeakerHint
        self.detectedSpeakerCount = detectedSpeakerCount
        self.rawDiarizationSegmentCount = rawDiarizationSegmentCount
        self.segmentsPerSpeaker = segmentsPerSpeaker
        self.speakingTimeMsPerSpeaker = speakingTimeMsPerSpeaker
        self.assignmentSummary = assignmentSummary
        self.warnings = warnings
    }

    public init(
        transcriptionSourceType: Transcription.SourceType,
        diarizedAudioSource: AudioSource?,
        requestedSpeakerHint: SpeakerCountHint?,
        diarizationResult: MacParakeetDiarizationResult,
        assignmentSummary: WordSpeakerAssignmentSummary
    ) {
        self.init(
            transcriptionSourceType: transcriptionSourceType,
            diarizedAudioSource: diarizedAudioSource,
            requestedSpeakerHint: requestedSpeakerHint,
            detectedSpeakerCount: diarizationResult.speakerCount,
            rawDiarizationSegmentCount: diarizationResult.segments.count,
            segmentsPerSpeaker: Self.segmentsPerSpeaker(diarizationResult.segments),
            speakingTimeMsPerSpeaker: Self.speakingTimeMsPerSpeaker(diarizationResult.segments),
            assignmentSummary: assignmentSummary,
            warnings: Self.warnings(
                requestedSpeakerHint: requestedSpeakerHint,
                detectedSpeakerCount: diarizationResult.speakerCount,
                diarizedAudioSource: diarizedAudioSource,
                assignmentSummary: assignmentSummary
            )
        )
    }

    private static func segmentsPerSpeaker(_ segments: [SpeakerSegment]) -> [String: Int] {
        segments.reduce(into: [:]) { counts, segment in
            counts[segment.speakerId, default: 0] += 1
        }
    }

    private static func speakingTimeMsPerSpeaker(_ segments: [SpeakerSegment]) -> [String: Int] {
        segments.reduce(into: [:]) { totals, segment in
            totals[segment.speakerId, default: 0] += max(0, segment.endMs - segment.startMs)
        }
    }

    private static func warnings(
        requestedSpeakerHint: SpeakerCountHint?,
        detectedSpeakerCount: Int,
        diarizedAudioSource: AudioSource?,
        assignmentSummary: WordSpeakerAssignmentSummary
    ) -> [DiarizationQualityWarning] {
        var warnings: [DiarizationQualityWarning] = []

        if let exact = requestedSpeakerHint?.exact {
            if detectedSpeakerCount < exact {
                warnings.append(.init(
                    kind: .speakerCountBelowHint,
                    observed: Double(detectedSpeakerCount),
                    threshold: Double(exact),
                    denominator: nil
                ))
            } else if detectedSpeakerCount > exact {
                warnings.append(.init(
                    kind: .speakerCountAboveHint,
                    observed: Double(detectedSpeakerCount),
                    threshold: Double(exact),
                    denominator: nil
                ))
            }
        } else {
            if let minimum = requestedSpeakerHint?.minimum, detectedSpeakerCount < minimum {
                warnings.append(.init(
                    kind: .speakerCountBelowHint,
                    observed: Double(detectedSpeakerCount),
                    threshold: Double(minimum),
                    denominator: nil
                ))
            }
            if let maximum = requestedSpeakerHint?.maximum, detectedSpeakerCount > maximum {
                warnings.append(.init(
                    kind: .speakerCountAboveHint,
                    observed: Double(detectedSpeakerCount),
                    threshold: Double(maximum),
                    denominator: nil
                ))
            }
        }

        let eligibleDiarizedWords = max(assignmentSummary.totalWords, 0)
        if eligibleDiarizedWords > 0 {
            let fallbackRate = Double(assignmentSummary.fallbackNearestWords) / Double(eligibleDiarizedWords)
            if fallbackRate > DiarizationQualityWarningThresholds.highFallbackAssignmentRate {
                warnings.append(.init(
                    kind: .highFallbackAssignmentRate,
                    observed: fallbackRate,
                    threshold: DiarizationQualityWarningThresholds.highFallbackAssignmentRate,
                    denominator: .init(name: "eligibleDiarizedWords", count: eligibleDiarizedWords)
                ))
            }
        }

        if diarizedAudioSource == .system, assignmentSummary.totalWords > 0 {
            let totalSystemWords = Double(assignmentSummary.totalWords)
            let diarizedSystemWords = assignmentSummary.directOverlapWords + assignmentSummary.fallbackNearestWords
            let systemCoverage = Double(diarizedSystemWords) / totalSystemWords
            if systemCoverage < DiarizationQualityWarningThresholds.lowSystemDiarizedCoverage {
                warnings.append(.init(
                    kind: .lowSystemDiarizedCoverage,
                    observed: systemCoverage,
                    threshold: DiarizationQualityWarningThresholds.lowSystemDiarizedCoverage,
                    denominator: .init(name: "totalSystemWords", count: assignmentSummary.totalWords)
                ))
            }

            let sourceOnlyRate = Double(assignmentSummary.sourceOnlyWords) / totalSystemWords
            if sourceOnlyRate > DiarizationQualityWarningThresholds.highSourceOnlyWordRate {
                warnings.append(.init(
                    kind: .highSourceOnlyWordRate,
                    observed: sourceOnlyRate,
                    threshold: DiarizationQualityWarningThresholds.highSourceOnlyWordRate,
                    denominator: .init(name: "totalSystemWords", count: assignmentSummary.totalWords)
                ))
            }
        }

        return warnings
    }
}

public struct DiarizationQualityWarning: Codable, Sendable, Equatable {
    public var kind: DiarizationQualityWarningKind
    public var observed: Double
    public var threshold: Double
    public var denominator: DiarizationQualityWarningDenominator?

    public init(
        kind: DiarizationQualityWarningKind,
        observed: Double,
        threshold: Double,
        denominator: DiarizationQualityWarningDenominator? = nil
    ) {
        self.kind = kind
        self.observed = observed
        self.threshold = threshold
        self.denominator = denominator
    }
}

public struct DiarizationQualityWarningDenominator: Codable, Sendable, Equatable {
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public enum DiarizationQualityWarningKind: String, Codable, Sendable, Equatable {
    case speakerCountBelowHint
    case speakerCountAboveHint
    case lowSystemDiarizedCoverage
    case highFallbackAssignmentRate
    case highSourceOnlyWordRate
}

enum DiarizationQualityWarningThresholds {
    static let lowSystemDiarizedCoverage = 0.70
    static let highFallbackAssignmentRate = 0.30
    static let highSourceOnlyWordRate = 0.30
}
