import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Live Captions window: real-time transcript and translation side by side,
/// without recording a meeting.
struct LiveCaptionsView: View {
    @Bindable var viewModel: LiveCaptionsViewModel

    @AppStorage(UserDefaultsAppRuntimePreferences.meetingCaptionFontSizeKey)
    private var fontSize: Double = 20
    @State private var copied = false

    private static let fontSizeRange: ClosedRange<Double> = 13...44
    private static let bottomID = "live-captions-bottom"
    private static let visibleLineCount = 60

    private struct Row: Identifiable, Equatable {
        let id: String
        let speaker: String?
        let original: String
        let isFinal: Bool
        let translation: String?
    }

    private var translation: LiveTranslationViewModel { viewModel.liveTranslation }

    // Explicitly typed values: inline mixed Double/CGFloat arithmetic inside
    // view builders stalls the type checker.
    private var textSize: CGFloat { CGFloat(fontSize) }
    private var speakerSize: CGFloat { max(CGFloat(11), CGFloat(fontSize * 0.55)) }
    private var hintSize: CGFloat { max(CGFloat(12), CGFloat(fontSize * 0.7)) }
    private var rowSpacing: CGFloat { CGFloat(fontSize * 0.5) }

    private var isRightToLeft: Bool { translation.language?.isRightToLeft ?? false }
    private var translationAlignment: Alignment { isRightToLeft ? .trailing : .leading }
    private var translationDirection: LayoutDirection { isRightToLeft ? .rightToLeft : .leftToRight }
    private var translationHeader: String { translation.language?.displayName ?? "Translation" }

    private var translateTitle: String {
        guard let language = translation.language else { return "Translate" }
        return "Translate: " + language.displayName
    }

    private var startTitle: String {
        switch viewModel.state {
        case .running: return "Stop"
        case .starting: return "Starting…"
        case .idle, .failed: return "Start"
        }
    }

    private var startIcon: String {
        viewModel.isRunning || viewModel.isBusy ? "stop.fill" : "play.fill"
    }

    private var failureMessage: String? {
        if case .failed(let message) = viewModel.state { return message }
        return viewModel.notice
    }

    private var emptyTitle: String {
        viewModel.isRunning ? "Listening…" : "Press Start to show live captions"
    }

    private var missingTranslationHint: String {
        translation.isAvailable ? "Choose a language in Translate" : "Set up an AI provider to translate"
    }

    private var rows: [Row] {
        var previousSource: AudioSource?
        var result: [Row] = []
        for line in viewModel.lines.suffix(Self.visibleLineCount) {
            let changed = line.source != previousSource
            previousSource = line.source
            result.append(
                Row(
                    id: line.id,
                    speaker: changed ? Self.label(for: line.source) : nil,
                    original: line.text,
                    isFinal: line.isFinal,
                    translation: translation.translation(forLineID: line.id)
                ))
        }
        return result
    }

    private static func label(for source: AudioSource) -> String {
        source == .microphone ? "Microphone" : "Computer audio"
    }

    private func languageTitle(_ language: TranslationLanguage) -> String {
        language.displayName + " · " + language.nativeName
    }

    private func originalColor(_ row: Row) -> Color {
        row.isFinal ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            failureBanner
            Divider().opacity(0.4)
            content
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var failureBanner: some View {
        if let failureMessage {
            Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.warningAmber)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            startButton
            sourcePicker
            translateMenu
            translationStatus
            Spacer()
            iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy everything", action: copyAll)
                .disabled(viewModel.lines.isEmpty)
            iconButton("trash", help: "Clear", action: viewModel.clear)
                .disabled(viewModel.lines.isEmpty)
            iconButton("textformat.size.smaller", help: "Smaller text", action: decreaseFontSize)
            iconButton("textformat.size.larger", help: "Larger text", action: increaseFontSize)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.top, 28)  // clears the transparent title bar
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var startButton: some View {
        if viewModel.isRunning {
            Button(action: viewModel.toggle) {
                Label(startTitle, systemImage: startIcon)
            }
            .parakeetAction(.secondary)
            .controlSize(.small)
        } else {
            Button(action: viewModel.toggle) {
                Label(startTitle, systemImage: startIcon)
            }
            .parakeetAction(.primary)
            .controlSize(.small)
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $viewModel.sourceMode) {
            Text("Computer audio").tag(MeetingAudioSourceMode.systemOnly)
            Text("Microphone").tag(MeetingAudioSourceMode.microphoneOnly)
            Text("Both").tag(MeetingAudioSourceMode.microphoneAndSystem)
        }
        .labelsHidden()
        .fixedSize()
        .disabled(viewModel.isRunning || viewModel.isBusy)
        .help("What to listen to. Change it while stopped.")
    }

    @ViewBuilder
    private var translationStatus: some View {
        if translation.errorMessage != nil {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
                .help("Translation paused. Choose Retry Translation in the Translate menu.")
        } else if translation.isTranslating {
            ProgressView().controlSize(.mini)
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var translateMenu: some View {
        Menu {
            Button(action: turnTranslationOff) {
                menuItem("Off", isSelected: translation.language == nil)
            }
            Divider()
            ForEach(TranslationLanguage.allCases) { language in
                Button(action: { translation.language = language }) {
                    menuItem(languageTitle(language), isSelected: translation.language == language)
                }
                .disabled(!translation.isAvailable)
            }
            Divider()
            Picker("Speed", selection: speedBinding) {
                ForEach(LiveTranslationViewModel.Speed.allCases) { speed in
                    Text(speed.title).tag(speed)
                }
            }
            if translation.errorMessage != nil {
                Divider()
                Button("Retry Translation", action: translation.retry)
            }
        } label: {
            Label(translateTitle, systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var speedBinding: Binding<LiveTranslationViewModel.Speed> {
        Binding(get: { translation.speed }, set: { translation.speed = $0 })
    }

    @ViewBuilder
    private func menuItem(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func turnTranslationOff() {
        translation.language = nil
    }

    private func decreaseFontSize() {
        fontSize = max(Self.fontSizeRange.lowerBound, fontSize - 2)
    }

    private func increaseFontSize() {
        fontSize = min(Self.fontSizeRange.upperBound, fontSize + 2)
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.transcriptText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            copied = false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let rows = self.rows
        if rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        headers
                        ForEach(rows) { row in
                            captionRow(row)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(DesignSystem.Spacing.md)
                }
                .onChange(of: rows) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Text(emptyTitle)
                .font(.system(size: hintSize))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(
                "Audio is streamed to your online speech service and nothing is saved. To keep a recording and transcript, use meeting recording instead."
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headers: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
            Text("Original")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(translationHeader)
                .frame(maxWidth: .infinity, alignment: translationAlignment)
        }
        .font(DesignSystem.Typography.caption.weight(.semibold))
        .foregroundStyle(DesignSystem.Colors.textTertiary)
    }

    private func captionRow(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let speaker = row.speaker {
                Text(speaker)
                    .font(.system(size: speakerSize, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                Text(row.original)
                    .font(.system(size: textSize))
                    .foregroundStyle(originalColor(row))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                translationCell(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, translationDirection)
            }
        }
    }

    @ViewBuilder
    private func translationCell(_ row: Row) -> some View {
        if let text = row.translation {
            Text(text)
                .font(.system(size: textSize))
                .foregroundStyle(DesignSystem.Colors.accent)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
        } else if translation.language == nil {
            Text(missingTranslationHint)
                .font(.system(size: hintSize))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        } else {
            Text("…")
                .font(.system(size: textSize))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
    }
}
