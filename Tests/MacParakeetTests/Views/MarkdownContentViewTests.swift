import Foundation
@testable import MacParakeet
import SwiftStreamingMarkdown
import XCTest

final class MarkdownContentViewTests: XCTestCase {
    func testStreamingSourcePublishesAccumulatedSnapshots() async {
        let source = MarkdownSnapshotSource(initialContent: "# Sum")
        var iterator = source.text.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, "# Sum")
        source.send("# Summary\n\n- [ ] Review")
        let updated = await iterator.next()
        XCTAssertEqual(updated, "# Summary\n\n- [ ] Review")
    }

    func testStreamingSourceReplaysLatestSnapshotAfterConsumerCancellation() async {
        let source = MarkdownSnapshotSource(initialContent: "# First visit")
        let subscribed = expectation(description: "First renderer consumed its snapshot")
        let firstRenderer = Task {
            var iterator = source.text.makeAsyncIterator()
            let initial = await iterator.next()
            XCTAssertEqual(initial, "# First visit")
            subscribed.fulfill()
            return await iterator.next()
        }
        await fulfillment(of: [subscribed], timeout: 2)

        // Match SwiftStreamingMarkdown's StreamedMarkdownController.end() on disappearance.
        firstRenderer.cancel()
        let cancelledValue = await firstRenderer.value
        XCTAssertNil(cancelledValue)
        source.send("# Changed while hidden")

        // SwiftUI keeps the StateObject when the pane returns. A fresh renderer
        // must see both the latest hidden update and subsequent live snapshots.
        var returnedRenderer = source.text.makeAsyncIterator()
        let replayed = await returnedRenderer.next()
        XCTAssertEqual(replayed, "# Changed while hidden")
        source.send("# Continued after returning")
        let continued = await returnedRenderer.next()
        XCTAssertEqual(continued, "# Continued after returning")
    }

    func testCancellingOldRendererDoesNotTerminateReplacementSubscription() async {
        let source = MarkdownSnapshotSource(initialContent: "Initial")
        let subscribed = expectation(description: "Old renderer subscribed")
        let oldRenderer = Task {
            var iterator = source.text.makeAsyncIterator()
            _ = await iterator.next()
            subscribed.fulfill()
            return await iterator.next()
        }
        await fulfillment(of: [subscribed], timeout: 2)
        var replacement = source.text.makeAsyncIterator()
        oldRenderer.cancel()
        _ = await oldRenderer.value
        let initial = await replacement.next()
        XCTAssertEqual(initial, "Initial")

        source.send("Replacement remains live")
        let next = await replacement.next()
        XCTAssertEqual(next, "Replacement remains live")
    }

    func testTableExportPreservesMarkdownSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("table.md")
        let content = "| Owner | Action |\n| --- | --- |\n| Élodie | Review **today** |\n"

        try await MarkdownTableExporter.write(content, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), content)
    }

    func testTableExportPropagatesDestinationWriteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file cannot contain an exported table, regardless of the
        // current user's filesystem permissions or whether tests run as root.
        let parentFile = directory.appendingPathComponent("not-a-directory")
        try "Keep this existing file".write(to: parentFile, atomically: true, encoding: .utf8)

        do {
            try await MarkdownTableExporter.write("| Table |", to: parentFile.appendingPathComponent("table.md"))
            XCTFail("The UI must receive the write error to present Export Failed")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        XCTAssertEqual(try String(contentsOf: parentFile, encoding: .utf8), "Keep this existing file")
    }

    func testKitchenSinkAndIncompleteSnapshotsProduceRenderableContent() async {
        let parser = MarkdownParserImpl()
        let config = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: false)
        let fixtures = [
            """
            # Summary

            **Bold**, *italic*, ~~removed~~, `inline code`, and [web](https://example.com).

            - Parent
              - Nested
            - [x] Done
            - [ ] Next

            3. Third
            4. Fourth

            | Item | Owner | Status |
            |:-----|:-----:|-------:|
            | API | **Sam** | Done |

            > Quoted context

            ```swift
            let value = 42
            ```

            ---
            """,
            "**unfinished emphasis",
            "```swift\nlet value = 42",
            "| Item | Owner |\n|:--|--:|\n| Work",
        ]

        for fixture in fixtures {
            let rendered = await parser.parse(text: fixture, config: config)
            XCTAssertNotEqual(rendered, .empty, "Fixture should stay readable: \(fixture)")
        }
    }

    func testLinkPolicyAllowsOnlyWebLinks() {
        XCTAssertTrue(MarkdownContentPolicy.isAllowedLink(URL(string: "https://example.com/path")!))
        XCTAssertTrue(MarkdownContentPolicy.isAllowedLink(URL(string: "HTTP://example.com")!))

        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "file:///tmp/private.txt")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "data:text/plain,secret")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "mailto:test@example.com")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "/relative/path")!))
    }

    func testRenderConfigurationKeepsImagesDisabledAndSelectionEnabled() {
        let config = MarkdownContentConfiguration.make(baseFontSize: 15, isStreaming: false)

        XCTAssertFalse(config.imageConfig.enabled)
        XCTAssertTrue(config.imageConfig.allowedImageTypes.isEmpty)
        XCTAssertTrue(config.textSelectionConfig.isEnabled)
        XCTAssertFalse(config.shouldAnimateText)
    }

    func testStreamingConfigurationOnlyEnablesTextAnimation() {
        let staticConfig = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: false)
        let streamingConfig = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: true)

        XCTAssertFalse(staticConfig.shouldAnimateText)
        XCTAssertTrue(streamingConfig.shouldAnimateText)
        XCTAssertEqual(staticConfig.imageConfig, streamingConfig.imageConfig)
        XCTAssertEqual(staticConfig.paragraphStyle, streamingConfig.paragraphStyle)
        XCTAssertEqual(staticConfig.tableStyle, streamingConfig.tableStyle)
    }
}
