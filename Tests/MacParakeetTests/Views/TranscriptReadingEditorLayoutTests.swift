import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import XCTest

@testable import MacParakeet

@MainActor
final class TranscriptReadingEditorLayoutTests: XCTestCase {
    private final class CountingHost<Content: View>: NSHostingView<Content> {
        var layoutCount = 0
        override func layout() {
            layoutCount += 1
            super.layout()
        }
    }

    func testLongMeetingOnlyCreatesVisibleFieldsAndRetainsEditsAfterScrolling() throws {
        let drafts = (0..<1_600).map { index in
            TranscriptReadingDraft(
                target: .init(
                    anchorTranscriptSegmentIDs: [],
                    wordRange: .init(startIndex: index * 6, endIndexExclusive: index * 6 + 6)
                ),
                originalText: "We should review the next steps.",
                text: "We should review the next steps."
            )
        }
        let start = Date()
        let session = TranscriptReadingEditSession(drafts: drafts)
        let host = CountingHost(
            rootView: ScrollView {
                VStack {
                    Text("Transcript")
                    TranscriptReadingEditor(session: session, font: .body)
                }
                .padding(24)
            })
        // A layout loop blocks XCTest's main actor; the watchdog must run elsewhere.
        let watchdog = DispatchWorkItem { fatalError("Reading editor layout did not finish within 120 seconds") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer { watchdog.cancel() }
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        pump(0.1)
        let fields = editableFields(host)
        print(
            "Reading editor: 1600 passages, \(fields.count) native fields, \(Date().timeIntervalSince(start)) seconds to first layout"
        )
        XCTAssertGreaterThan(fields.count, 0)
        XCTAssertLessThan(fields.count, 100, "Opening an editor must not construct every passage's native text field")

        // Drive the native field editor, not just the view model, to prove the binding.
        let first = try XCTUnwrap(fields.first)
        XCTAssertTrue(window.makeFirstResponder(first))
        let fieldEditor = try XCTUnwrap(first.currentEditor() as? NSTextView)
        fieldEditor.selectAll(nil)
        fieldEditor.insertText(
            "A corrected first passage.\nA second line after a multiline paste.",
            replacementRange: fieldEditor.selectedRange())
        pump(0.1)
        XCTAssertEqual(session.passages[0].text, "A corrected first passage.\nA second line after a multiline paste.")
        XCTAssertTrue(session.hasChanges)
        window.makeFirstResponder(nil)
        session.passages[1].removed = true
        pump(0.1)

        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        let lastPassage = try XCTUnwrap(session.passages.last)
        lastPassage.text = "The final passage is visible."
        for _ in 0..<3 {
            // Lazy height estimates change as distant rows materialize. Drive
            // the native scrollbar to its current end until the last row appears.
            let bottomDeadline = Date().addingTimeInterval(2)
            repeat {
                scroll.contentView.scroll(
                    to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                pump(0.05)
            } while !editableFields(host).contains(where: { $0.stringValue == "The final passage is visible." })
                && Date() < bottomDeadline
            XCTAssertTrue(editableFields(host).contains { $0.stringValue == "The final passage is visible." })
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.2)
        }
        XCTAssertEqual(session.passages[0].text, "A corrected first passage.\nA second line after a multiline paste.")
        XCTAssertTrue(
            editableFields(host).contains {
                $0.stringValue == "A corrected first passage.\nA second line after a multiline paste."
            })
        XCTAssertTrue(session.passages[1].removed)
        session.passages[1].removed = false
        lastPassage.text = drafts.last!.text
        XCTAssertEqual(
            session.command(),
            .reviseText(changes: [
                .replace(
                    target: drafts[0].target, text: "A corrected first passage.\nA second line after a multiline paste."
                )
            ]))

        // Require a quiet interval after recycling variable-height rows.
        let deadline = Date().addingTimeInterval(5)
        var lastCount = host.layoutCount
        var quietSince = Date()
        while Date() < deadline {
            pump(0.05)
            if host.layoutCount != lastCount {
                lastCount = host.layoutCount
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 0.5 {
                return
            }
        }
        XCTFail("Editor layout did not settle after scrolling")
    }

    private func editableFields(_ view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
