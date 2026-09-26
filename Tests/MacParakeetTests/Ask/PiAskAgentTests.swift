import Darwin
import XCTest
@testable import MacParakeetCore

final class PiAskAgentTests: XCTestCase {
    private let context = LLMExecutionContext(providerConfig: .localCLI())
    private let request = AskAgentRequest(
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        scopeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        messages: [ChatMessage(role: .user, content: "Question")]
    )

    func testMissingPackagedRuntimeFailsBeforeAnyModelOrToolCall() async throws {
        let agent = PiAskAgent(
            nodeURL: URL(fileURLWithPath: "/missing/node"),
            helperURL: URL(fileURLWithPath: "/missing/helper.cjs"))
        do {
            _ = try await agent.run(
                request: request, client: RoutingLLMClient(), context: context,
                tool: { _, _ in
                    XCTFail("Tool should not execute"); return "{}"
                },
                onEvent: { _ in })
            XCTFail("Missing runtime was accepted")
        } catch AskAgentError.unavailable {}
    }

    func testPublishedPiInvestigatesThreeSyntheticSourcesAndStreamsBeforeTerminal() async throws {
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AskAgentHelper/dist/ask-helper.cjs")
        let configuredNode = ProcessInfo.processInfo.environment["MACPARAKEET_ASK_TEST_NODE"]
        let candidateNodes = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        let node =
            configuredNode.map { URL(fileURLWithPath: $0) }
            ?? candidateNodes.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        if configuredNode != nil {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: node?.path ?? ""))
            XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
        }
        guard let node, FileManager.default.isExecutableFile(atPath: node.path),
            FileManager.default.fileExists(atPath: helper.path)
        else {
            throw XCTSkip("Local Pi helper build and Node executable are unavailable")
        }
        let client = ScriptedPiLLMClient()
        let recorder = PiTestRecorder()
        let agent = PiAskAgent(nodeURL: node, helperURL: helper)
        let question = AskAgentRequest(
            runID: UUID(), scopeID: UUID(),
            messages: [ChatMessage(role: .user, content: "Compare the launch date across A, B, and C.")]
        )
        let answer = try await agent.run(
            request: question, client: client, context: context,
            tool: { name, argumentsJSON in
                await recorder.tool(name)
                let args = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]
                )
                switch name {
                case "list_sources":
                    return #"{"sources":[{"id":"A"},{"id":"B"},{"id":"C"}]}"#
                case "search":
                    XCTAssertEqual(args["query"] as? String, "launch")
                    return #"{"results":[{"sourceID":"A"},{"sourceID":"B"},{"sourceID":"C"}]}"#
                case "read":
                    let source = try XCTUnwrap(args["sourceID"] as? String)
                    return "{\"sourceID\":\"\(source)\",\"passage\":\"Launch date changed in \(source).\"}"
                default:
                    XCTFail("Unexpected tool \(name)")
                    return "{}"
                }
            },
            onEvent: { event in
                switch event {
                case .activity: break
                case .text(let chunk):
                    let terminal = await client.terminalObserved()
                    await recorder.chunk(chunk, beforeTerminal: !terminal)
                }
            }
        )
        XCTAssertEqual(answer, "A said June; B said July; C said August [E1][E2][E3].")
        let called = await recorder.toolNames
        XCTAssertEqual(called, ["list_sources", "search", "read", "read", "read"])
        let streamed = await recorder.streamedText
        XCTAssertEqual(streamed, answer)
        let early = await recorder.sawChunkBeforeTerminal
        XCTAssertTrue(early)
    }

    func testHelperBudgetFailurePreservesItsSafeCategory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("budget.sh")
        let content = """
            #!/bin/sh
            read input
            printf '%s\\n' '{"v":1,"kind":"error","runID":"00000000-0000-0000-0000-000000000001","scopeID":"00000000-0000-0000-0000-000000000002","requestID":"ignored","code":"budgetExceeded","message":"private payload"}'
            """
        try content.write(to: script, atomically: true, encoding: .utf8)
        let agent = PiAskAgent(nodeURL: URL(fileURLWithPath: "/bin/sh"), helperURL: script)
        do {
            _ = try await agent.run(
                request: request, client: RoutingLLMClient(), context: context,
                tool: { _, _ in
                    XCTFail("Tool should not execute"); return "{}"
                }, onEvent: { _ in })
            XCTFail("Budget failure was accepted")
        } catch AskAgentError.budgetExceeded(let message) {
            XCTAssertFalse(message.contains("private payload"))
        }
    }

    func testClosedHelperInputCannotTerminateHostWithSIGPIPE() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest", "MacParakeetTests.PiAskAgentTests/testClosedHelperInputChild",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MACPARAKEET_ASK_SIGPIPE_CHILD": directory.path
        ]) { _, new in new }
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning else {
            XCTFail("SIGPIPE child did not finish within 20 seconds")
            return
        }
        process.waitUntilExit()
        let diagnostics = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(process.terminationReason, .exit, diagnostics)
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("survived").path), diagnostics)
    }

    func testClosedHelperInputChild() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACPARAKEET_ASK_SIGPIPE_CHILD"] else { return }
        // Only this isolated xctest child changes process-wide signal handling.
        // The host application must rely on the per-descriptor protection.
        Darwin.signal(SIGPIPE, SIG_DFL)
        let directory = URL(fileURLWithPath: path)
        let script = directory.appendingPathComponent("closed-input.sh")
        let content = """
            #!/bin/sh
            read input
            exec 0<&-
            printf '%s\\n' '{"v":1,"kind":"tool","runID":"00000000-0000-0000-0000-000000000001","scopeID":"00000000-0000-0000-0000-000000000002","requestID":"00000000-0000-0000-0000-000000000001:tool","toolName":"list_sources","argumentsJSON":"{}"}'
            exec /bin/sleep 10
            """
        try content.write(to: script, atomically: true, encoding: .utf8)
        let agent = PiAskAgent(nodeURL: URL(fileURLWithPath: "/bin/sh"), helperURL: script)
        let recorder = PiTestRecorder()
        do {
            _ = try await agent.run(
                request: request, client: RoutingLLMClient(), context: context,
                tool: { name, _ in
                    await recorder.tool(name); return "{}"
                }, onEvent: { _ in })
            XCTFail("Closed helper input was accepted")
        } catch {
            let calls = await recorder.toolNames
            XCTAssertEqual(calls, ["list_sources"])
            try Data("survived".utf8).write(to: directory.appendingPathComponent("survived"))
        }
    }

    func testWrongRunIDFromHelperFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("wrong-id.sh")
        let content = """
            #!/bin/sh
            read input
            printf '%s\\n' '{"v":1,"kind":"done","runID":"wrong","scopeID":"00000000-0000-0000-0000-000000000002","requestID":"ignored","answerSHA256":"ignored"}'
            """
        try content.write(to: script, atomically: true, encoding: .utf8)
        let agent = PiAskAgent(nodeURL: URL(fileURLWithPath: "/bin/sh"), helperURL: script)
        do {
            _ = try await agent.run(
                request: request, client: RoutingLLMClient(), context: context,
                tool: { _, _ in
                    XCTFail("Tool should not execute"); return "{}"
                },
                onEvent: { _ in })
            XCTFail("Wrong run ID was accepted")
        } catch AskAgentError.protocolViolation {}
    }
}

private actor PiTestRecorder {
    private(set) var toolNames: [String] = []
    private(set) var streamedText = ""
    private(set) var sawChunkBeforeTerminal = false
    func tool(_ name: String) { toolNames.append(name) }
    func chunk(_ text: String, beforeTerminal: Bool) {
        streamedText += text
        if beforeTerminal { sawChunkBeforeTerminal = true }
    }
}

private final class ScriptedPiLLMClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    private var reachedTerminal = false
    private let decisions = [
        #"{"query":"","sourceID":"","start":0,"limit":0,"kind":"tool","toolName":"list_sources"}"#,
        #"{"query":"launch","sourceID":"","start":0,"limit":3,"kind":"tool","toolName":"search"}"#,
        #"{"query":"","sourceID":"A","start":0,"limit":5,"kind":"tool","toolName":"read"}"#,
        #"{"query":"","sourceID":"B","start":0,"limit":5,"kind":"tool","toolName":"read"}"#,
        #"{"query":"","sourceID":"C","start":0,"limit":5,"kind":"tool","toolName":"read"}"#,
        #"{"query":"","sourceID":"","start":0,"limit":0,"kind":"final","toolName":""}"#,
    ]

    func chatCompletion(
        messages: [ChatMessage], context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(content: takeDecision(), model: "scripted")
    }

    private func takeDecision() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < decisions.count else { return "invalid extra turn" }
        let value = decisions[nextIndex]
        nextIndex += 1
        return value
    }

    func terminalObserved() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedTerminal
    }

    private func markTerminal() {
        lock.lock()
        reachedTerminal = true
        lock.unlock()
    }

    func chatCompletionStream(
        messages: [ChatMessage], context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func chatCompletionDetailedStream(
        messages: [ChatMessage], context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.text("A said June; "))
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.markTerminal()
                continuation.yield(.text("B said July; C said August [E1][E2][E3]."))
                continuation.yield(
                    .completed(LLMStreamTerminal(provider: "scripted", model: "scripted", stopReason: "stop")))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func testConnection(context: LLMExecutionContext) async throws {}
    func listModels(context: LLMExecutionContext) async throws -> [String] { [] }
}
