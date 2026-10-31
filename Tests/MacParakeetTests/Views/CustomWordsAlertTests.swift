import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import XCTest

@testable import MacParakeet

/// Exercise the native alert, not only the view model's deletion methods.
@MainActor
final class CustomWordsAlertTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    func testSingleRuleAlertOffersCancelAndDeleteAndDefaultsToCancel() async throws {
        let fixture = makeFixture()
        defer { close(fixture.window) }
        fixture.model.requestDelete(fixture.words[0])
        let alert = try await deletionAlert(in: fixture.window)
        let cancel = try button("Cancel", in: alert)
        let delete = try button("Delete", in: alert)
        XCTAssertEqual(cancel.keyEquivalent, "\r")
        XCTAssertNotEqual(delete.keyEquivalent, "\r")
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertTrue(delete.isEnabled)
        cancel.performClick(nil)
        try await waitUntil { fixture.model.pendingDeletion == nil && fixture.window.attachedSheet == nil }
        XCTAssertEqual(Set(fixture.repo.words.map(\.id)), Set(fixture.words.map(\.id)))

        fixture.model.requestDelete(fixture.words[0])
        let secondAlert = try await deletionAlert(in: fixture.window)
        try button("Delete", in: secondAlert).performClick(nil)
        try await waitUntil { fixture.model.words.count == 2 }
        XCTAssertEqual(Set(fixture.repo.words.map(\.id)), Set(fixture.words.dropFirst().map(\.id)))
    }

    func testBulkRuleAlertDeletesOnlyTheConfirmedSelection() async throws {
        let fixture = makeFixture()
        defer { close(fixture.window) }
        fixture.model.startSelection()
        fixture.model.toggleSelection(for: fixture.words[0].id)
        fixture.model.toggleSelection(for: fixture.words[2].id)
        fixture.model.requestDeleteSelection()
        let alert = try await deletionAlert(in: fixture.window)
        XCTAssertEqual(try button("Cancel", in: alert).keyEquivalent, "\r")
        try button("Delete", in: alert).performClick(nil)
        try await waitUntil { fixture.model.words.count == 1 }
        XCTAssertEqual(fixture.repo.words.map(\.id), [fixture.words[1].id])
        XCTAssertFalse(fixture.model.isSelecting)
        XCTAssertNil(fixture.model.pendingDeletion)
    }

    private func makeFixture() -> (
        window: NSWindow, model: CustomWordsViewModel, repo: MockCustomWordRepository, words: [CustomWord]
    ) {
        let words = [
            CustomWord(word: "alpha", replacement: "Alpha"),
            CustomWord(word: "beta", replacement: "Beta"),
            CustomWord(word: "gamma", replacement: "Gamma"),
        ]
        let repo = MockCustomWordRepository()
        repo.words = words
        let model = CustomWordsViewModel()
        model.configure(repo: repo)
        let host = NSHostingView(
            rootView: CustomWordsView(
                viewModel: model,
                recognitionStatus: .init(title: "Clean corrections", detail: "Synthetic correction rules")
            ))
        let window = OffscreenWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, model, repo, words)
    }

    private func deletionAlert(in window: NSWindow) async throws -> NSWindow {
        try await waitUntil { window.attachedSheet != nil }
        return try XCTUnwrap(window.attachedSheet)
    }

    private func button(_ title: String, in window: NSWindow) throws -> NSButton {
        let content = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The native vocabulary alert did not reach its expected state")
        throw NSError(domain: "CustomWordsAlertTests", code: 1)
    }

    private func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
    }
}
