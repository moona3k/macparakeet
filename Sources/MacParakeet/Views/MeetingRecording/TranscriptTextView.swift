import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Native NSTextView wrapper for performant, fully-selectable transcript rendering.
/// Supports drag-selection across the entire transcript with colored speaker headers.
/// Uses incremental suffix updates so live transcript changes don't rebuild the full document.
struct TranscriptTextView: NSViewRepresentable {
    let lines: [MeetingRecordingPreviewLine]
    let autoScroll: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 8)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        let coordinator = context.coordinator
        if let firstChangedIndex = firstChangedLineIndex(
            oldLines: coordinator.lastRenderedLines,
            newLines: lines
        ) {
            let replaceLocation = firstChangedIndex < coordinator.lineRanges.count
                ? coordinator.lineRanges[firstChangedIndex].location
                : storage.length
            let replaceLength = storage.length - replaceLocation
            let renderedSuffix = buildRenderedSlice(
                for: lines.suffix(from: firstChangedIndex),
                startingIndex: firstChangedIndex,
                previousSource: firstChangedIndex > 0 ? lines[firstChangedIndex - 1].source : nil,
                isFirstInDocument: firstChangedIndex == 0
            )
            storage.replaceCharacters(
                in: NSRange(location: replaceLocation, length: replaceLength),
                with: renderedSuffix.attributedString
            )
            coordinator.lastRenderedLines = lines
            coordinator.lineRanges =
                Array(coordinator.lineRanges.prefix(firstChangedIndex))
                + renderedSuffix.lineRanges.map {
                    NSRange(location: replaceLocation + $0.location, length: $0.length)
                }

            if autoScroll {
                DispatchQueue.main.async {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        }

        if autoScroll != coordinator.lastAutoScroll, autoScroll {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
        coordinator.lastAutoScroll = autoScroll
    }

    final class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var lastRenderedLines: [MeetingRecordingPreviewLine] = []
        var lineRanges: [NSRange] = []
        var lastAutoScroll: Bool = true
    }

    private struct RenderedSlice {
        let attributedString: NSAttributedString
        let lineRanges: [NSRange]
    }

    /// Build a rendered suffix for a slice of lines.
    /// Tracks speaker changes relative to `previousSource` so headers appear correctly
    /// even when replacing only the changed suffix.
    private func buildRenderedSlice(
        for lineSlice: ArraySlice<MeetingRecordingPreviewLine>,
        startingIndex: Int,
        previousSource: AudioSource?,
        isFirstInDocument: Bool
    ) -> RenderedSlice {
        let result = NSMutableAttributedString()
        var lineRanges: [NSRange] = []
        var previousSource = previousSource
        var isFirstLine = isFirstInDocument

        let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let serifFont: NSFont = {
            let descriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
                .withDesign(.serif) ?? NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
            return NSFont(descriptor: descriptor, size: 13) ?? bodyFont
        }()

        let speakerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let dotFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let timestampFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let textColor = NSColor.white.withAlphaComponent(0.9)
        let timestampColor = NSColor.white.withAlphaComponent(0.3)

        for (offset, line) in lineSlice.enumerated() {
            let globalIndex = startingIndex + offset
            let lineStart = result.length
            let speakerChanged = isFirstLine || line.source != previousSource
            isFirstLine = false

            if speakerChanged {
                let headerPara = NSMutableParagraphStyle()
                headerPara.lineSpacing = 2
                headerPara.paragraphSpacingBefore = globalIndex > 0 ? 10 : 0
                headerPara.paragraphSpacing = 2

                let color = nsColor(for: line.source)

                let dot = NSAttributedString(string: "\u{25CF} ", attributes: [
                    .font: dotFont,
                    .foregroundColor: color,
                    .paragraphStyle: headerPara,
                ])
                result.append(dot)

                let speaker = NSAttributedString(string: "\(line.speakerLabel)  ", attributes: [
                    .font: speakerFont,
                    .foregroundColor: color.withAlphaComponent(0.85),
                ])
                result.append(speaker)

                let timestamp = NSAttributedString(string: "\(line.timestamp)\n", attributes: [
                    .font: timestampFont,
                    .foregroundColor: timestampColor,
                ])
                result.append(timestamp)
            }

            let textPara = NSMutableParagraphStyle()
            textPara.lineSpacing = 2
            textPara.firstLineHeadIndent = 11
            textPara.headIndent = 11

            let text = NSAttributedString(string: "\(line.text)\n", attributes: [
                .font: serifFont,
                .foregroundColor: textColor,
                .paragraphStyle: textPara,
            ])
            result.append(text)

            lineRanges.append(NSRange(location: lineStart, length: result.length - lineStart))
            previousSource = line.source
        }

        return RenderedSlice(attributedString: result, lineRanges: lineRanges)
    }

    private func firstChangedLineIndex(
        oldLines: [MeetingRecordingPreviewLine],
        newLines: [MeetingRecordingPreviewLine]
    ) -> Int? {
        let sharedCount = min(oldLines.count, newLines.count)
        for index in 0..<sharedCount where oldLines[index] != newLines[index] {
            return index
        }
        return oldLines.count == newLines.count ? nil : sharedCount
    }

    private func nsColor(for source: AudioSource?) -> NSColor {
        switch source {
        case .microphone:
            return NSColor(DesignSystem.Colors.accent)
        case .system:
            return NSColor(DesignSystem.Colors.speakerColor(for: 0))
        case .none:
            return NSColor(DesignSystem.Colors.textSecondary)
        }
    }
}
