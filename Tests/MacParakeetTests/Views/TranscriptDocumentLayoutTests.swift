import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import SwiftStreamingMarkdown
import XCTest

@testable import MacParakeet

/// Native rendering checks for the shared result/chat Markdown surface.
/// Parsing is awaited explicitly so assertions cannot pass on an empty view.
@MainActor
final class TranscriptDocumentLayoutTests: XCTestCase {
    /// Exercise the offered pane size independently of the test machine's display.
    private final class LayoutWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    private final class Host<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    func testLongMarkdownAndWideBlocksStayInsideCompactAndRegularPanes() async throws {
        let paragraph = String(repeating: "Review the next milestone and confirm the owner. ", count: 12)
        let chapters = (0..<80).map { "## Chapter \($0 + 1)\n\n\(paragraph)\n\n- [ ] Confirm the next action\n" }
            .joined(separator: "\n")
        let headers = (0..<12).map { "Column \($0)" }.joined(separator: " | ")
        let separators = Array(repeating: "---", count: 12).joined(separator: " | ")
        let cells = Array(repeating: "A wider value to inspect", count: 12).joined(separator: " | ")
        let text =
            "| \(headers) |\n| \(separators) |\n| \(cells) |\n\n```text\n\(String(repeating: "long_code_identifier_", count: 50))\n```\n\n"
            + chapters
        let config = MarkdownContentConfiguration.make(baseFontSize: 15, isStreaming: false)
        let document = await MarkdownParserImpl().parse(text: text, config: config)
        XCTAssertNotEqual(document, .empty)
        for width in [500.0, 900.0] {
            try checkLayout(
                DocumentView(renderableDocument: document, config: config)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled),
                width: width, label: "Markdown"
            )
        }
    }

    func testTenThousandWordSelectableTextStaysInsidePaneAndSettles() throws {
        let text = (0..<1_000).map { _ in "One two three four five six seven eight nine ten." }.joined(
            separator: "\n\n")
        try checkLayout(
            Text(text)
                .font(DesignSystem.Typography.transcriptBody(scale: 1))
                .textSelection(.enabled)
                .lineSpacing(6)
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading),
            width: 500, label: "Plain transcript"
        )
    }

    func testSavedResultEditorUsesAvailableHeight() throws {
        let suite = makeIsolatedDefaultsSuite("TranscriptDocumentLayoutTests.")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let transcription = Transcription(
            fileName: "Synthetic meeting", cleanTranscript: "Synthetic transcript", status: .completed)
        let model = TranscriptionViewModel(defaults: defaults)
        model.currentTranscription = transcription
        let results = PromptResultsViewModel()
        let result = PromptResult(
            transcriptionId: transcription.id, promptName: "Summary", promptContent: "Summarize",
            content: "A synthetic summary.")
        let host = Host(
            rootView: TranscriptResultView(
                transcription: transcription, viewModel: model,
                chatViewModel: TranscriptChatViewModel(), promptResultsViewModel: results,
                promptsViewModel: PromptsViewModel()
            ).defaultAppStorage(defaults))
        let window = LayoutWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1_100, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        results.promptResults = [result]
        results.beginEditingPromptResult(result)
        model.hasPromptResultTabs = true
        model.selectedTab = .result(id: result.id)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first(where: \.isEditable))
        let smallContent = window.contentRect(forFrameRect: window.frame)
        XCTAssertEqual(smallContent.width, 1_100, accuracy: 1)
        XCTAssertEqual(smallContent.height, 650, accuracy: 1)
        let smallHeight = try XCTUnwrap(editor.enclosingScrollView).contentView.bounds.height
        window.setContentSize(NSSize(width: 1_100, height: 950))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let largeContent = window.contentRect(forFrameRect: window.frame)
        XCTAssertEqual(largeContent.width, 1_100, accuracy: 1)
        XCTAssertEqual(largeContent.height, 950, accuracy: 1)
        let largeHeight = try XCTUnwrap(editor.enclosingScrollView).contentView.bounds.height
        print("Result editor viewport: \(smallHeight) -> \(largeHeight) for +300 pt window height")
        XCTAssertGreaterThan(
            largeHeight - smallHeight, 200,
            "The editor must grow with its pane instead of remaining a minimum-height field inside a scroll view")
        window.setContentSize(NSSize(width: 500, height: 650))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertLessThanOrEqual(host.bounds.width, 501)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let editorFrame = host.convert(scroll.bounds, from: scroll)
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 120)
        XCTAssertGreaterThanOrEqual(editorFrame.minX, host.bounds.minX)
        XCTAssertLessThanOrEqual(editorFrame.maxX, host.bounds.maxX)
        results.cancelEditingPromptResult()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(descendants(host).contains { ($0 as? NSTextView)?.isEditable == true })
        XCTAssertLessThanOrEqual(host.bounds.width, 501)
        XCTAssertEqual(results.promptResults.first?.content, result.content)

    }

    /// Empty meeting notes leave the result page quiet. The old status caption
    /// must not return and inflate the window minimum.
    func testEmptyMeetingNotesLeaveTheResultPageQuiet() throws {
        let rendered = try renderMeetingResult(currentNotes: nil, includeMeetingNotesSnapshot: false)
        assertMeetingNotesInstructionStaysOutOfTheColumn(rendered.text)
        assertResultWindowStaysAtOfferedSize(rendered.window)
    }

    /// A result that ignored current notes keeps the instruction out of the
    /// column. The control shares the toolbar row, so it must not add a caption
    /// that raises the window minimum the way the old paragraph did.
    func testOmittedMeetingNotesStayOutOfTheResultColumn() throws {
        let empty = try renderMeetingResult(currentNotes: nil, includeMeetingNotesSnapshot: false)
        let omitted = try renderMeetingResult(
            currentNotes: "Spell it Siobhan.", includeMeetingNotesSnapshot: false)
        assertMeetingNotesInstructionStaysOutOfTheColumn(omitted.text)
        XCTAssertFalse(empty.text.contains("Notes not included"))
        assertResultWindowStaysAtOfferedSize(omitted.window)
        XCTAssertEqual(
            omitted.window.contentMinSize.height,
            empty.window.contentMinSize.height,
            accuracy: 8,
            "The notes control must stay on the toolbar row instead of adding a caption"
        )
    }

    func testSentMeetingNotesKeepASnapshotRow() throws {
        let empty = try renderMeetingResult(currentNotes: nil, includeMeetingNotesSnapshot: false)
        let sent = try renderMeetingResult(
            currentNotes: "Spell it Siobhan.",
            includeMeetingNotesSnapshot: true,
            userNotesSnapshot: "Spell it Siobhan."
        )
        assertMeetingNotesInstructionStaysOutOfTheColumn(sent.text)
        assertResultWindowStaysAtOfferedSize(sent.window)
        XCTAssertGreaterThan(
            sent.window.contentMinSize.height,
            empty.window.contentMinSize.height + 16,
            "A sent notes snapshot keeps its disclosure row"
        )
    }

    private func assertMeetingNotesInstructionStaysOutOfTheColumn(_ text: String) {
        XCTAssertFalse(text.contains("Meeting notes are off"))
        XCTAssertFalse(text.contains("No meeting notes were recorded"))
        XCTAssertFalse(text.contains("Meeting notes context was not recorded"))
    }

    private func assertResultWindowStaysAtOfferedSize(_ window: NSWindow) {
        let minimum = window.contentMinSize
        let content = window.contentRect(forFrameRect: window.frame)
        print("Meeting result window minimum \(minimum), content \(content.size)")
        XCTAssertLessThanOrEqual(
            minimum.height, content.height,
            "Result notes UI must not raise the window minimum above the pane"
        )
        XCTAssertEqual(content.height, 650, accuracy: 1)
        XCTAssertEqual(content.width, 1_100, accuracy: 1)
    }

    private func renderMeetingResult(
        currentNotes: String?,
        includeMeetingNotesSnapshot: Bool,
        userNotesSnapshot: String? = nil
    ) throws -> (window: NSWindow, text: String) {
        let suite = makeIsolatedDefaultsSuite("TranscriptDocumentLayoutTests.meeting-notes.\(UUID().uuidString).")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let transcription = Transcription(
            fileName: "Synthetic meeting",
            cleanTranscript: "Synthetic transcript",
            status: .completed,
            sourceType: .meeting,
            userNotes: currentNotes
        )
        let model = TranscriptionViewModel(defaults: defaults)
        model.currentTranscription = transcription
        let results = PromptResultsViewModel()
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptId: UUID(),
            promptName: "Summary",
            promptContent: "Summarize",
            content: "A synthetic summary that stays in the column.",
            userNotesSnapshot: userNotesSnapshot,
            includeMeetingNotesSnapshot: includeMeetingNotesSnapshot
        )
        let host = Host(
            rootView: TranscriptResultView(
                transcription: transcription, viewModel: model,
                chatViewModel: TranscriptChatViewModel(), promptResultsViewModel: results,
                promptsViewModel: PromptsViewModel()
            ).defaultAppStorage(defaults))
        let window = LayoutWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1_100, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        results.promptResults = [result]
        model.hasPromptResultTabs = true
        model.selectedTab = .result(id: result.id)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        addTeardownBlock { window.orderOut(nil) }
        return (window, renderedText(in: host))
    }

    private func renderedText(in view: NSView) -> String {
        var parts: [String] = []
        if let label = view.accessibilityLabel(), !label.isEmpty { parts.append(label) }
        if let value = view.accessibilityValue() as? String, !value.isEmpty { parts.append(value) }
        let identifier = view.accessibilityIdentifier()
        if !identifier.isEmpty { parts.append(identifier) }
        if let field = view as? NSTextField { parts.append(field.stringValue) }
        if let textView = view as? NSTextView { parts.append(textView.string) }
        if let button = view as? NSButton, !button.title.isEmpty { parts.append(button.title) }
        for subview in view.subviews {
            parts.append(renderedText(in: subview))
        }
        return parts.joined(separator: "\n")
    }

    private func checkLayout<Content: View>(_ content: Content, width: Double, label: String) throws {
        let watchdog = DispatchWorkItem { fatalError("Document layout exceeded 120 seconds") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer { watchdog.cancel() }
        let start = Date()
        let host = Host(
            rootView: ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Document")
                    content
                }
                .padding(24)
            })
        let window = LayoutWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        print(
            "\(label), width \(width): first layout \(Date().timeIntervalSince(start)) s, "
                + "document \(document.bounds.width), pane \(scroll.bounds.width), "
                + "clip \(scroll.contentView.bounds.width)"
        )
        XCTAssertLessThanOrEqual(host.bounds.width, width + 1)
        // Compare against the scroll view, not its clip. A visible legacy scroller
        // insets the clip by about 15 pt while the document stays at the pane width.
        XCTAssertLessThanOrEqual(
            document.bounds.width,
            scroll.bounds.width + 1,
            "Wide content must stay inside the offered pane, not the scroller inset"
        )
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        for _ in 0..<2 {
            scroll.contentView.scroll(
                to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let deadline = Date().addingTimeInterval(5)
        var count = host.layouts
        var quietSince = Date()
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if host.layouts != count {
                count = host.layouts
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 0.5 {
                return
            }
        }
        XCTFail("\(label) did not settle after scrolling")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
