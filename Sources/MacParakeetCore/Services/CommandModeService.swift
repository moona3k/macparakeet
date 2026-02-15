import Foundation

public enum CommandModeState: Sendable, Equatable {
    case idle
    case recording
    case processing
}

public enum CommandModeServiceError: Error, LocalizedError, Equatable {
    case notRecording
    case emptySelectedText
    case emptyCommand
    case emptyTransformedText

    public var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Not currently recording a command."
        case .emptySelectedText:
            return "Select text first."
        case .emptyCommand:
            return "Couldn't hear a command — try again."
        case .emptyTransformedText:
            return "The model returned empty output."
        }
    }
}

public protocol CommandModeServiceProtocol: Sendable {
    func startRecording() async throws
    func stopRecordingAndProcess(selectedText: String) async throws -> CommandModeResult
    func cancelRecording() async
    var state: CommandModeState { get async }
    var audioLevel: Float { get async }
}

public actor CommandModeService: CommandModeServiceProtocol {
    private let audioProcessor: AudioProcessorProtocol
    private let sttClient: STTClientProtocol
    private let llmService: any LLMServiceProtocol
    private let generationOptionsProvider: @Sendable () -> LLMGenerationOptions

    private var _state: CommandModeState = .idle

    public var state: CommandModeState { _state }
    public var audioLevel: Float { get async { await audioProcessor.audioLevel } }

    public init(
        audioProcessor: AudioProcessorProtocol,
        sttClient: STTClientProtocol,
        llmService: any LLMServiceProtocol,
        generationOptionsProvider: (@Sendable () -> LLMGenerationOptions)? = nil
    ) {
        self.audioProcessor = audioProcessor
        self.sttClient = sttClient
        self.llmService = llmService
        self.generationOptionsProvider = generationOptionsProvider ?? {
            LLMGenerationOptions(
                temperature: 0.6,
                topP: 0.95,
                maxTokens: 1024,
                timeoutSeconds: 120
            )
        }
    }

    public func startRecording() async throws {
        guard _state == .idle else { return }
        _state = .recording
        do {
            try await audioProcessor.startCapture()
        } catch {
            _state = .idle
            throw error
        }
    }

    public func stopRecordingAndProcess(selectedText: String) async throws -> CommandModeResult {
        guard _state == .recording else {
            throw CommandModeServiceError.notRecording
        }

        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else {
            _state = .idle
            throw CommandModeServiceError.emptySelectedText
        }

        _state = .processing

        do {
            let audioURL = try await audioProcessor.stopCapture()
            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            let stt = try await sttClient.transcribe(audioPath: audioURL.path)
            let command = stt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                _state = .idle
                throw CommandModeServiceError.emptyCommand
            }

            let task = LLMTask.commandTransform(command: command, selectedText: selected)
            let request = LLMRequest(
                prompt: LLMPromptBuilder.userPrompt(for: task),
                systemPrompt: LLMPromptBuilder.systemPrompt(for: task),
                options: generationOptionsProvider()
            )
            let response = try await llmService.generate(request: request)
            let transformed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transformed.isEmpty else {
                _state = .idle
                throw CommandModeServiceError.emptyTransformedText
            }

            _state = .idle
            return CommandModeResult(
                spokenCommand: command,
                selectedText: selected,
                transformedText: transformed,
                modelID: response.modelID,
                durationSeconds: response.durationSeconds
            )
        } catch {
            _state = .idle
            throw error
        }
    }

    public func cancelRecording() async {
        if _state == .recording {
            _ = try? await audioProcessor.stopCapture()
        }
        _state = .idle
    }
}
