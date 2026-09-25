import Darwin
import CryptoKit
import Foundation

/// Runs the pinned Pi agent core in a private, single-run Node helper.
/// The process has no provider credentials and can only call the supplied tool closure.
public struct PiAskAgent: AskAgentRunning {
    private let explicitNodeURL: URL?
    private let explicitHelperURL: URL?
    private static let frameLimit = 64 * 1_024
    private static let deadlineNanoseconds: UInt64 = 180 * 1_000_000_000

    public init() {
        explicitNodeURL = nil
        explicitHelperURL = nil
    }

    public init(nodeURL: URL, helperURL: URL) {
        explicitNodeURL = nodeURL
        explicitHelperURL = helperURL
    }

    public func run(
        request: AskAgentRequest,
        client: any LLMClientProtocol,
        context: LLMExecutionContext,
        tool: @escaping @Sendable (String, String) async throws -> String,
        onEvent: @escaping @Sendable (AskAgentEvent) async -> Void
    ) async throws -> String {
        let (nodeURL, helperURL) = try resolvePaths()
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [helperURL.path]
        process.currentDirectoryURL = helperURL.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LANG": "C", "TZ": "UTC"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            stop(process)
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await exchange(
                        process: process, input: input, output: output,
                        request: request, client: client, context: context,
                        tool: tool, onEvent: onEvent
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.deadlineNanoseconds)
                    throw AskAgentError.budgetExceeded("Ask deadline exceeded")
                }
                do {
                    let answer = try await group.next()!
                    group.cancelAll()
                    return answer
                } catch {
                    group.cancelAll()
                    stop(process)
                    throw error
                }
            }
        } onCancel: {
            stop(process)
        }
    }

    private func exchange(
        process: Process, input: Pipe, output: Pipe, request: AskAgentRequest,
        client: any LLMClientProtocol, context: LLMExecutionContext,
        tool: @escaping @Sendable (String, String) async throws -> String,
        onEvent: @escaping @Sendable (AskAgentEvent) async -> Void
    ) async throws -> String {
        let runID = request.runID.uuidString
        let scopeID = request.scopeID.uuidString
        let startID = "\(runID):start"
        let history = request.messages.map { ["role": $0.role.rawValue, "content": $0.modelContent] }
        try send(
            [
                "v": 1, "kind": "start", "runID": runID, "scopeID": scopeID,
                "requestID": startID, "messages": history,
            ], to: input.fileHandleForWriting)
        var activeRequestIDs = Set<String>()
        let finalBuffer = AskFinalTextBuffer()
        var echoedText = ""
        var finalRequestStarted = false
        for try await line in Self.lines(from: output.fileHandleForReading) {
            try Task.checkCancellation()
            guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                frame["v"] as? Int == 1,
                frame["runID"] as? String == runID,
                frame["scopeID"] as? String == scopeID,
                let kind = frame["kind"] as? String
            else {
                throw AskAgentError.protocolViolation("Invalid Ask helper frame identity")
            }
            let requestID = frame["requestID"] as? String
            switch kind {
            case "modelDecision", "modelFinal":
                guard let requestID, requestID.hasPrefix("\(runID):"),
                    activeRequestIDs.insert(requestID).inserted,
                    let messageObjects = frame["messages"] as? [[String: String]],
                    messageObjects.count <= 100
                else {
                    throw AskAgentError.protocolViolation("Invalid Ask model request")
                }
                let messages = try Self.decodeMessages(messageObjects)
                do {
                    if kind == "modelDecision" {
                        let action = try await AskModelBridge.decide(
                            messages: messages, client: client, context: context)
                        var payload: [String: Any] = ["kind": action.kind]
                        if let name = action.toolName, let arguments = action.arguments {
                            payload["toolName"] = name
                            payload["arguments"] = arguments
                        }
                        try send(
                            reply(
                                "decision", runID: runID, scopeID: scopeID, requestID: requestID,
                                extra: ["action": payload]), to: input.fileHandleForWriting)
                    } else {
                        guard !finalRequestStarted else {
                            throw AskAgentError.protocolViolation("Duplicate Ask final request")
                        }
                        finalRequestStarted = true
                        try await AskModelBridge.streamFinal(messages: messages, client: client, context: context) {
                            chunk in
                            try await finalBuffer.append(chunk, onEvent: onEvent)
                            try send(
                                reply(
                                    "modelChunk", runID: runID, scopeID: scopeID, requestID: requestID,
                                    extra: ["text": chunk]), to: input.fileHandleForWriting)
                        }
                        try send(
                            reply("modelDone", runID: runID, scopeID: scopeID, requestID: requestID),
                            to: input.fileHandleForWriting)
                    }
                } catch {
                    try? send(
                        reply(
                            "error", runID: runID, scopeID: scopeID, requestID: requestID,
                            extra: ["message": "Model request failed"]), to: input.fileHandleForWriting)
                    throw error
                }
            case "tool":
                guard let requestID, requestID.hasPrefix("\(runID):"),
                    activeRequestIDs.insert(requestID).inserted,
                    let name = frame["toolName"] as? String,
                    ["list_sources", "search", "read", "get_summary"].contains(name),
                    let argumentsJSON = frame["argumentsJSON"] as? String,
                    argumentsJSON.utf8.count <= 4_096,
                    let argumentsData = argumentsJSON.data(using: .utf8),
                    (try? JSONSerialization.jsonObject(with: argumentsData)) is [String: Any]
                else {
                    throw AskAgentError.protocolViolation("Invalid Ask tool request")
                }
                do {
                    let result = try await tool(name, argumentsJSON)
                    guard result.utf8.count <= 32 * 1_024,
                        let data = result.data(using: .utf8),
                        (try? JSONSerialization.jsonObject(with: data)) != nil
                    else {
                        throw AskAgentError.protocolViolation("Invalid or oversized Ask tool result")
                    }
                    try send(
                        reply(
                            "toolResult", runID: runID, scopeID: scopeID, requestID: requestID,
                            extra: ["resultJSON": result]), to: input.fileHandleForWriting)
                } catch {
                    try? send(
                        reply(
                            "error", runID: runID, scopeID: scopeID, requestID: requestID,
                            extra: ["message": "Scoped source operation failed"]), to: input.fileHandleForWriting)
                    throw error
                }
            case "activity":
                guard requestID == nil, let text = frame["text"] as? String, text.count <= 200 else {
                    throw AskAgentError.protocolViolation("Invalid Ask activity")
                }
                await onEvent(.activity(text))
            case "text":
                guard requestID == nil, let text = frame["text"] as? String,
                    text.utf8.count <= Self.frameLimit
                else {
                    throw AskAgentError.protocolViolation("Invalid Ask answer text")
                }
                echoedText += text
                guard echoedText.count <= 80_000 else { throw AskAgentError.budgetExceeded("Ask answer exceeds limit") }
            case "done":
                let answer = await finalBuffer.text
                let digest = SHA256.hash(data: Data(answer.utf8)).map { String(format: "%02x", $0) }.joined()
                guard requestID == startID, let finalDigest = frame["answerSHA256"] as? String,
                    !answer.isEmpty, echoedText == answer, finalDigest == digest
                else {
                    throw AskAgentError.protocolViolation("Ask answer did not match streamed text")
                }
                return answer
            case "error":
                throw AskAgentError.failed((frame["message"] as? String) ?? "Ask helper failed")
            default:
                throw AskAgentError.protocolViolation("Unknown Ask helper frame")
            }
        }
        throw AskAgentError.failed("Ask helper exited before completing")
    }

    private static func decodeMessages(_ objects: [[String: String]]) throws -> [ChatMessage] {
        try objects.map { object in
            guard Set(object.keys) == Set(["role", "content"]),
                let roleName = object["role"], let role = ChatMessage.Role(rawValue: roleName),
                let content = object["content"]
            else {
                throw AskAgentError.protocolViolation("Invalid Ask model message")
            }
            return ChatMessage(role: role, content: content)
        }
    }

    private func reply(
        _ kind: String, runID: String, scopeID: String, requestID: String,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        ["v": 1, "kind": kind, "runID": runID, "scopeID": scopeID, "requestID": requestID]
            .merging(extra) { _, new in new }
    }

    private func send(_ frame: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard data.count <= Self.frameLimit else {
            throw AskAgentError.budgetExceeded("Ask IPC frame exceeds limit")
        }
        try handle.write(contentsOf: data + Data([0x0a]))
    }

    private static func lines(from handle: FileHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task.detached {
                do {
                    var buffer = Data()
                    var bytes = [UInt8](repeating: 0, count: 4_096)
                    while true {
                        let count = bytes.withUnsafeMutableBytes { raw in
                            Darwin.read(handle.fileDescriptor, raw.baseAddress, raw.count)
                        }
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        for byte in bytes.prefix(count) {
                            if byte == 0x0a {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            } else {
                                buffer.append(byte)
                                if buffer.count > frameLimit {
                                    throw AskAgentError.protocolViolation("Ask helper frame exceeds limit")
                                }
                            }
                        }
                    }
                    if !buffer.isEmpty {
                        throw AskAgentError.protocolViolation("Ask helper ended mid-frame")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    private func resolvePaths() throws -> (URL, URL) {
        if let explicitNodeURL, let explicitHelperURL {
            guard explicitNodeURL.path.hasPrefix("/"), explicitHelperURL.path.hasPrefix("/"),
                FileManager.default.isExecutableFile(atPath: explicitNodeURL.path),
                FileManager.default.fileExists(atPath: explicitHelperURL.path)
            else {
                throw AskAgentError.unavailable("Ask helper or Node runtime is unavailable")
            }
            return (explicitNodeURL, explicitHelperURL)
        }
        let resources = Bundle.main.resourceURL
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDirectory = executable.deletingLastPathComponent()
        let candidates = [
            resources,
            executableDirectory.appendingPathComponent("libexec/macparakeet-cli", isDirectory: true),
            executableDirectory.deletingLastPathComponent()
                .appendingPathComponent("libexec/macparakeet-cli", isDirectory: true),
        ].compactMap { $0 }
        for base in candidates {
            let arch = ProcessInfo.processInfo.machineHardwareName == "x86_64" ? "node-x86_64" : "node-arm64"
            let node = [base.appendingPathComponent(arch), base.appendingPathComponent("node")]
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            let helper = base.appendingPathComponent("AskAgentHelper/ask-helper.cjs")
            if let node, FileManager.default.fileExists(atPath: helper.path) { return (node, helper) }
        }
        throw AskAgentError.unavailable("The packaged Ask helper and Node runtime were not found")
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if process.isRunning && process.processIdentifier == pid { Darwin.kill(pid, SIGKILL) }
        }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }
}

private actor AskFinalTextBuffer {
    private(set) var text = ""

    func append(_ chunk: String, onEvent: @Sendable (AskAgentEvent) async -> Void) async throws {
        text += chunk
        guard text.count <= 80_000 else {
            throw AskAgentError.budgetExceeded("Ask answer exceeds limit")
        }
        await onEvent(.text(chunk))
    }
}
