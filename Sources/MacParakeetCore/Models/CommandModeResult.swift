import Foundation

public struct CommandModeResult: Sendable, Equatable {
    public let spokenCommand: String
    public let selectedText: String
    public let transformedText: String
    public let modelID: String
    public let durationSeconds: TimeInterval

    public init(
        spokenCommand: String,
        selectedText: String,
        transformedText: String,
        modelID: String,
        durationSeconds: TimeInterval
    ) {
        self.spokenCommand = spokenCommand
        self.selectedText = selectedText
        self.transformedText = transformedText
        self.modelID = modelID
        self.durationSeconds = durationSeconds
    }
}
