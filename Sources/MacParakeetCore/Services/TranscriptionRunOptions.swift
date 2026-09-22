import Foundation

public struct TranscriptionRunOptions: Sendable, Equatable {
    public var diarizationOptions: DiarizationOptions
    public var includeDiarizationReport: Bool

    public static let `default` = Self()

    public init(
        diarizationOptions: DiarizationOptions = .default,
        includeDiarizationReport: Bool = false
    ) {
        self.diarizationOptions = diarizationOptions
        self.includeDiarizationReport = includeDiarizationReport
    }
}

public struct TranscriptionRunResult: Sendable {
    public var transcription: Transcription
    public var diarizationQualityReport: DiarizationQualityReport?

    public init(
        transcription: Transcription,
        diarizationQualityReport: DiarizationQualityReport? = nil
    ) {
        self.transcription = transcription
        self.diarizationQualityReport = diarizationQualityReport
    }
}
