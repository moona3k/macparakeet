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

        // Match SwiftUI cancelling the structured consumer on disappearance.
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

    @MainActor
    func testCancelledParseCannotOverwriteReplacementRenderer() async {
        let source = MarkdownSnapshotSource(initialContent: "Old result")
        let config = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: false)
        let oldDocument = RenderableDocument(plainText: "Old result", config: config)
        let newDocument = RenderableDocument(plainText: "New result", config: config)
        let oldParseStarted = expectation(description: "Old parse suspended")
        let replacementPublished = expectation(description: "Replacement published")
        var finishOldParse: CheckedContinuation<RenderableDocument, Never>?
        var published: [RenderableDocument] = []

        let oldRenderer = Task {
            await MarkdownSnapshotRenderer.render(
                source: source, config: config,
                parse: { _, _ in
                    await withCheckedContinuation { continuation in
                        finishOldParse = continuation
                        oldParseStarted.fulfill()
                    }
                }, publish: { published.append($0) })
        }
        await fulfillment(of: [oldParseStarted], timeout: 2)
        oldRenderer.cancel()
        source.send("New result")

        let replacement = Task {
            await MarkdownSnapshotRenderer.render(
                source: source, config: config,
                parse: { text, _ in
                    XCTAssertEqual(text, "New result")
                    return newDocument
                },
                publish: {
                    published.append($0)
                    replacementPublished.fulfill()
                })
        }
        await fulfillment(of: [replacementPublished], timeout: 2)

        // The dependency parser need not observe cancellation. Its late result
        // must still be discarded after a replacement consumer has published.
        finishOldParse?.resume(returning: oldDocument)
        await oldRenderer.value
        replacement.cancel()
        await replacement.value
        XCTAssertEqual(published, [newDocument])
    }

    @MainActor
    func testRendererCoalescesSnapshotsWhileParsing() async {
        let source = MarkdownSnapshotSource(initialContent: "Initial")
        let config = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: true)
        let initialParseStarted = expectation(description: "Initial parse suspended")
        let latestPublished = expectation(description: "Latest snapshot published")
        var finishInitialParse: CheckedContinuation<RenderableDocument, Never>?
        var parsed: [String] = []
        var publishedCount = 0

        let renderer = Task {
            await MarkdownSnapshotRenderer.render(
                source: source, config: config,
                parse: { text, config in
                    parsed.append(text)
                    if text == "Initial" {
                        return await withCheckedContinuation { continuation in
                            finishInitialParse = continuation
                            initialParseStarted.fulfill()
                        }
                    }
                    return RenderableDocument(plainText: text, config: config)
                },
                publish: { _ in
                    publishedCount += 1
                    if publishedCount == 2 {
                        latestPublished.fulfill()
                    }
                })
        }
        await fulfillment(of: [initialParseStarted], timeout: 2)
        source.send("Intermediate")
        source.send("Latest")
        XCTAssertEqual(parsed, ["Initial"], "Parsing remains serial")
        finishInitialParse?.resume(returning: RenderableDocument(plainText: "Initial", config: config))
        await fulfillment(of: [latestPublished], timeout: 2)
        renderer.cancel()
        await renderer.value
        XCTAssertEqual(parsed, ["Initial", "Latest"])
    }

    func testTableExportPreservesProvidedTableMarkdown() async throws {
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
