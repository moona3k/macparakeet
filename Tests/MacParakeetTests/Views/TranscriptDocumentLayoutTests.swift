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
        let suite = "TranscriptDocumentLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let window = NSWindow(
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
        let smallHeight = try XCTUnwrap(editor.enclosingScrollView).contentView.bounds.height
        window.setContentSize(NSSize(width: 1_100, height: 950))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
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
        let window = NSWindow(
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
