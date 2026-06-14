#if DEBUG
import Foundation
import MacParakeetCore

@MainActor
final class DebugDictationPreviewQA {
    private static let launchArgument = "--qa-dictation-preview-overlay"
    private static let transcriptArgument = "--qa-dictation-preview-text"

    private let arguments: [String]
    private var overlayController: DictationOverlayController?
    private var waveformTask: Task<Void, Never>?

    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }

    init(arguments: [String] = CommandLine.arguments) {
        self.arguments = arguments
    }

    deinit {
        waveformTask?.cancel()
    }

    func show() {
        let viewModel = DictationOverlayViewModel()
        viewModel.state = .recording
        viewModel.sessionKind = .dictation
        viewModel.recordingMode = .persistent
        viewModel.recordingElapsedSeconds = 8
        viewModel.audioLevel = 0.45
        viewModel.liveTranscript = arguments.value(after: Self.transcriptArgument) ?? Self.defaultTranscript
        viewModel.onCancel = { [weak self] in self?.hide() }
        viewModel.onStop = { [weak self] in self?.hide() }
        viewModel.startTimer()

        let controller = DictationOverlayController(viewModel: viewModel)
        controller.show()
        overlayController = controller
        animateWaveform(for: viewModel)
    }

    private func hide() {
        waveformTask?.cancel()
        waveformTask = nil
        overlayController?.hide()
        overlayController = nil
    }

    private func animateWaveform(for viewModel: DictationOverlayViewModel) {
        waveformTask?.cancel()
        waveformTask = Task { @MainActor [weak viewModel] in
            let levels: [Float] = [0.18, 0.42, 0.74, 0.55, 0.88, 0.36, 0.62, 0.24]
            var index = 0

            while !Task.isCancelled {
                viewModel?.audioLevel = levels[index % levels.count]
                index += 1
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    private static let defaultTranscript = "Drafting the launch notes now. The live preview should update while the final transcript is still streaming in."
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard let index = firstIndex(of: flag) else { return nil }
        let valueIndex = self.index(after: index)
        guard valueIndex < endIndex else { return nil }
        return self[valueIndex]
    }
}
#endif
