import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Floating live captions for a meeting recording: the original transcript
/// and its translation side by side, following the newest lines.
struct MeetingCaptionView: View {
    @Bindable var viewModel: MeetingRecordingPanelViewModel
    var onClose: () -> Void
    @State private var scrollFollow = AskScrollFollowState()

    @AppStorage(UserDefaultsAppRuntimePreferences.meetingCaptionFontSizeKey)
    private var fontSize: Double = MeetingCaptionView.defaultFontSize

    static let defaultFontSize: Double = 20
    static let fontSizeRange: ClosedRange<Double> = 13...44
    /// Only the most recent lines are laid out; captions are for following
    /// along, and the full transcript stays in the meeting panel.
    static let visibleLineCount = 40

    private struct Row: Identifiable, Equatable {
        let id: String
        let speaker: String?
        let original: String
        let translation: String?
    }

    private var translation: LiveTranslationViewModel { viewModel.liveTranslation }

    // Sizes are computed once with explicit types; inline mixed
    // Double/CGFloat arithmetic inside view builders stalls the type checker.
    private var textSize: CGFloat { CGFloat(fontSize) }
    private var speakerSize: CGFloat { max(CGFloat(11), CGFloat(fontSize * 0.55)) }
    private var hintSize: CGFloat { max(CGFloat(12), CGFloat(fontSize * 0.7)) }
    private var emptySize: CGFloat { CGFloat(fontSize * 0.8) }
    private var rowSpacing: CGFloat { CGFloat(fontSize * 0.5) }

    private var translateMenuTitle: String {
        guard let language = translation.language else { return "Translate" }
        return "Translate: " + language.displayName
    }

    private var translationHeaderTitle: String {
        translation.language?.displayName ?? "Translation"
    }

    private var translationAlignment: Alignment {
        translationIsRightToLeft ? .trailing : .leading
    }

    private var translationDirection: LayoutDirection {
        translationIsRightToLeft ? .rightToLeft : .leftToRight
    }

    private var missingTranslationHint: String {
        translation.isAvailable ? "Choose a language above" : "Set up an AI provider to translate"
    }

    private func languageTitle(_ language: TranslationLanguage) -> String {
        language.displayName + " · " + language.nativeName
    }

    private func decreaseFontSize() {
        fontSize = max(Self.fontSizeRange.lowerBound, fontSize - 2)
    }

    private func increaseFontSize() {
        fontSize = min(Self.fontSizeRange.upperBound, fontSize + 2)
    }

    private var rows: [Row] {
        var previousSpeaker: String?
        return viewModel.previewLines.suffix(Self.visibleLineCount).map { line in
            let speakerChanged = line.speakerLabel != previousSpeaker
            previousSpeaker = line.speakerLabel
            return Row(
                id: line.id,
                speaker: speakerChanged ? line.speakerLabel : nil,
                original: line.text,
                translation: translation.translation(forLineID: line.id)
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider().opacity(0.4)
            captions
        }
        .background(.regularMaterial)
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Menu {
                Button {
                    translation.language = nil
                } label: {
                    menuItem("Off", isSelected: translation.language == nil)
                }
                Divider()
                ForEach(TranslationLanguage.allCases) { language in
                    Button {
                        translation.language = language
                    } label: {
                        menuItem(languageTitle(language), isSelected: translation.language == language)
                    }
                    .disabled(!translation.isAvailable)
                }
                if translation.errorMessage != nil {
                    Divider()
                    Button("Retry Translation") { translation.retry() }
                }
            } label: {
                Label(translateMenuTitle, systemImage: "globe")
                    .font(DesignSystem.Typography.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let error = translation.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .help("Live translation paused: \(error)")
            } else if translation.isTranslating {
                ProgressView().controlSize(.mini)
            }

            Spacer()

            Button(action: decreaseFontSize) {
                Image(systemName: "textformat.size.smaller")
            }
            .buttonStyle(.borderless)
            .help("Smaller text")
            .disabled(fontSize <= Self.fontSizeRange.lowerBound)

            Button(action: increaseFontSize) {
                Image(systemName: "textformat.size.larger")
            }
            .buttonStyle(.borderless)
            .help("Larger text")
            .disabled(fontSize >= Self.fontSizeRange.upperBound)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close captions")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.top, 26)  // clears the transparent title bar
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func menuItem(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Captions

    @ViewBuilder
    private var captions: some View {
        let rows = self.rows
        if rows.isEmpty {
            Text(viewModel.transcriptEmptyStateTitle)
                .font(.system(size: emptySize))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: rowSpacing) {
                            columnHeaders
                            ForEach(rows) { row in
                                captionRow(row)
                            }
                            Color.clear.frame(height: 1).id(Self.bottomID)
                        }
                        .padding(DesignSystem.Spacing.md)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(
                                    key: CaptionContentFrameKey.self,
                                    value: content.frame(in: .named("meetingCaptions")))
                            }
                        }
                    }
                    .coordinateSpace(name: "meetingCaptions")
                    .onPreferenceChange(CaptionContentFrameKey.self) { frame in
                        if scrollFollow.update(content: frame, viewportHeight: viewport.size.height) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        scrollFollow.resume()
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let bottomID = "caption-bottom"

    private var columnHeaders: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
            Text("Original")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(translationHeaderTitle)
                .frame(maxWidth: .infinity, alignment: translationAlignment)
        }
        .font(DesignSystem.Typography.caption.weight(.semibold))
        .foregroundStyle(DesignSystem.Colors.textTertiary)
    }

    private func captionRow(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let speaker = row.speaker, !speaker.isEmpty {
                Text(speaker)
                    .font(.system(size: speakerSize, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                Text(row.original)
                    .font(.system(size: textSize))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                translationCell(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Persian reads right-to-left: mirror this column only.
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
        } else if !translation.isAvailable || translation.language == nil {
            Text(missingTranslationHint)
                .font(.system(size: hintSize))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        } else {
            Text("…")
                .font(.system(size: textSize))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
    }

    private var translationIsRightToLeft: Bool {
        translation.language?.isRightToLeft ?? false
    }
}

private struct CaptionContentFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
