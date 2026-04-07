import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Native NSTextView wrapper for performant, fully-selectable transcript rendering.
/// Supports drag-selection across the entire transcript with colored speaker headers.
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
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let lineCount = lines.count
        if lineCount != context.coordinator.lastLineCount {
            let attrString = buildAttributedString()
            textView.textStorage?.setAttributedString(attrString)
            context.coordinator.lastLineCount = lineCount

            if autoScroll {
                DispatchQueue.main.async {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        } else if autoScroll != context.coordinator.lastAutoScroll, autoScroll {
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
        context.coordinator.lastAutoScroll = autoScroll
    }

    final class Coordinator {
        var textView: NSTextView?
        var scrollView: NSScrollView?
        var lastLineCount: Int = 0
        var lastAutoScroll: Bool = true
    }

    private func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previousSource: AudioSource? = nil

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

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 2
        bodyParagraph.paragraphSpacing = 0
        bodyParagraph.firstLineHeadIndent = 11

        let headerParagraph = NSMutableParagraphStyle()
        headerParagraph.lineSpacing = 2
        headerParagraph.paragraphSpacingBefore = result.length > 0 ? 8 : 0

        for (index, line) in lines.enumerated() {
            let speakerChanged = line.source != previousSource

            if speakerChanged {
                let headerPara = NSMutableParagraphStyle()
                headerPara.lineSpacing = 2
                headerPara.paragraphSpacingBefore = index > 0 ? 10 : 0
                headerPara.paragraphSpacing = 2

                let color = nsColor(for: line.source)

                let dot = NSAttributedString(string: "● ", attributes: [
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

            previousSource = line.source
        }

        return result
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
