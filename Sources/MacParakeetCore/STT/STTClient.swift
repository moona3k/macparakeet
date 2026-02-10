import Foundation
@preconcurrency import Dispatch
import os

/// STT client that manages the Python daemon lifecycle and communicates via JSON-RPC.
public actor STTClient: STTClientProtocol {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutRemainder = Data()
    private var requestId: Int = 0
    private var isStarted = false
    private var consecutiveCrashes = 0
    private let maxConsecutiveCrashes = 3
    private let pythonBootstrap: PythonBootstrap

    public init(pythonBootstrap: PythonBootstrap = PythonBootstrap()) {
        self.pythonBootstrap = pythonBootstrap
    }

    public func transcribe(audioPath: String) async throws -> STTResult {
        try await ensureRunning()

        requestId += 1
        let request = JSONRPCRequest(
            method: "transcribe",
            params: ["audio_path": .string(audioPath)],
            id: requestId
        )

        let responseData = try await sendRequest(request)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

        if let error = response.error {
            switch error.code {
            case -32001: throw STTError.modelNotLoaded
            case -32002: throw STTError.outOfMemory
            default:
                let reason = error.data?.reason ?? error.message
                throw STTError.transcriptionFailed(reason)
            }
        }

        guard let result = response.result else {
            throw STTError.invalidResponse
        }

        let words = (result.words ?? []).map { word in
            TimestampedWord(
                word: word.word,
                startMs: word.startMs,
                endMs: word.endMs,
                confidence: word.confidence
            )
        }

        consecutiveCrashes = 0
        return STTResult(text: result.text, words: words)
    }

    public func warmUp() async throws {
        try await ensureRunning()
    }

    public func isReady() async -> Bool {
        guard let process, process.isRunning else { return false }
        return isStarted
    }

    public func shutdown() async {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isStarted = false
        stdoutRemainder = Data()
    }

    // MARK: - Private

    private func ensureRunning() async throws {
        if let process, process.isRunning, isStarted {
            return
        }

        if consecutiveCrashes >= maxConsecutiveCrashes {
            throw STTError.daemonStartFailed(
                "Daemon crashed \(maxConsecutiveCrashes) times consecutively. Manual restart required."
            )
        }

        try await startDaemon()
    }

    private func startDaemon() async throws {
        let pythonPath = try await pythonBootstrap.ensureEnvironment()

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-m", "macparakeet_stt"]
        proc.environment = pythonBootstrap.daemonEnvironment()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] _ in
            Task { [weak self] in
                await self?.handleDaemonExit()
            }
        }

        do {
            try proc.run()
        } catch {
            consecutiveCrashes += 1
            throw STTError.daemonStartFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Wait for "ready" signal
        do {
            let readyLine = try await readLine(from: stdout, timeout: 30)
            guard readyLine.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" else {
                throw STTError.daemonStartFailed("Daemon did not send ready signal")
            }
        } catch {
            // Clean up half-initialized state
            proc.terminate()
            proc.waitUntilExit()

            let stderrOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            consecutiveCrashes += 1

            if let stderrOutput, !stderrOutput.isEmpty {
                throw STTError.daemonStartFailed("\(error.localizedDescription)\n\(stderrOutput)")
            }
            throw error
        }

        isStarted = true
        consecutiveCrashes = 0
    }

    private func handleDaemonExit() {
        isStarted = false
        consecutiveCrashes += 1
    }

    private func sendRequest(_ request: JSONRPCRequest) async throws -> Data {
        guard let stdinPipe, let stdoutPipe else {
            throw STTError.daemonNotRunning
        }

        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(contentsOf: "\n".utf8)

        stdinPipe.fileHandleForWriting.write(data)

        let responseLine = try await readLine(from: stdoutPipe, timeout: 60)
        guard let responseData = responseLine.data(using: .utf8) else {
            throw STTError.invalidResponse
        }

        return responseData
    }

    private func readLine(from pipe: Pipe, timeout: TimeInterval) async throws -> String {
        let fileHandle = pipe.fileHandleForReading

        // Serve buffered data first (if the previous read picked up multiple lines).
        if let newlineIdx = stdoutRemainder.firstIndex(of: 0x0A) {
            let lineData = stdoutRemainder.prefix(upTo: newlineIdx)
            stdoutRemainder.removeSubrange(..<stdoutRemainder.index(after: newlineIdx))
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw STTError.invalidResponse
            }
            return line
        }

        let buffer = OSAllocatedUnfairLock(initialState: stdoutRemainder)
        let resumed = OSAllocatedUnfairLock(initialState: false)

        @Sendable func tryExtractLine() -> Result<String, Error>? {
            buffer.withLock { data in
                guard let newlineIdx = data.firstIndex(of: 0x0A) else { return nil }
                let lineData = data.prefix(upTo: newlineIdx)
                data.removeSubrange(..<data.index(after: newlineIdx))
                guard let line = String(data: lineData, encoding: .utf8) else {
                    return .failure(STTError.invalidResponse)
                }
                return .success(line)
            }
        }

        do {
            let line = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                @Sendable func finish(_ result: Result<String, Error>) {
                    let alreadyResumed = resumed.withLock { value in
                        if value { return true }
                        value = true
                        return false
                    }
                    guard !alreadyResumed else { return }
                    fileHandle.readabilityHandler = nil
                    continuation.resume(with: result)
                }

                if let extracted = tryExtractLine() {
                    finish(extracted)
                    return
                }

                fileHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else {
                        finish(.failure(STTError.daemonNotRunning))
                        return
                    }

                    buffer.withLock { $0.append(chunk) }

                    if let extracted = tryExtractLine() {
                        finish(extracted)
                    }
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(STTError.timeout))
                }
            }

            stdoutRemainder = buffer.withLock { $0 }
            return line
        } catch {
            stdoutRemainder = buffer.withLock { $0 }
            throw error
        }
    }
}
