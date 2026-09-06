import AppKit
import Darwin

@main
struct ShutdownTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ShutdownError("FAIL: \(message)") }
    }

    static func expectFailure(_ fragment: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            try expect(String(describing: error).contains(fragment), "Unexpected failure: \(error)")
            return
        }
        throw ShutdownError("FAIL: Expected failure containing \(fragment)")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let literal = "/private/tmp/work(qa)[draft]+/.build/debug/MacParakeet"
        let matcher = try AppExecutableMatcher(paths: [literal])
        try expect(matcher.matches(literal), "Literal regex punctuation must match")
        try expect(!matcher.matches("/private/tmp/workqa/.build/debug/MacParakeet"), "Regex-shaped lookalike must not match")
        try expect(!matcher.matches("/bin/sh"), "An unrelated executable must not match its arguments")
        try expect(matcher.matches("/another/worktree/MacParakeet-Dev.app/Contents/MacOS/MacParakeet"), "Dev bundles in other worktrees remain covered")
        try expect(!matcher.matches("/another/worktree/MacParakeet-Dev.app/Contents/MacOS/MacParakeet-helper"), "Executable suffix must not match")
        try expectFailure("absolute") { _ = try AppExecutableMatcher(paths: ["relative/MacParakeet"]) }
        print("PASS: literal executable paths and Dev bundle scope")

        try expectFailure("At least one") { _ = try AppExecutableMatcher(paths: []) }
        for arguments in [[], ["10"]] {
            try expectFailure("at least one") { _ = try ShutdownRequest(arguments: arguments) }
        }
        for timeout in ["0", "-1", "nan", "inf", "invalid"] {
            try expectFailure("positive timeout") { _ = try ShutdownRequest(arguments: [timeout, literal]) }
        }
        let request = try ShutdownRequest(arguments: ["0.5", literal])
        try expect(request.timeout == 0.5 && request.matcher.matches(literal), "Valid CLI arguments must retain timeout and path")
        print("PASS: empty matcher and missing/invalid CLI arguments rejected before inspection")

        var clock: TimeInterval = 0
        var requested = 0
        let delayed = QuitTarget(pid: 101, requestQuit: { requested += 1; return true }, hasExited: { clock >= 0.4 })
        try quitNormally(targets: [delayed], timeout: 1, now: { clock }, pause: { clock += 0.1 })
        try expect(requested == 1 && clock >= 0.4, "Must await actual delayed exit")
        print("PASS: normal quit waits for observed exit")

        let refused = QuitTarget(pid: 102, requestQuit: { false }, hasExited: { false })
        try expectFailure("Normal quit request failed") {
            try quitNormally(targets: [refused], timeout: 1, now: { clock }, pause: { clock += 0.1 })
        }
        let cancelled = QuitTarget(pid: 103, requestQuit: { true }, hasExited: { false })
        try expectFailure("still open") {
            try quitNormally(targets: [cancelled], timeout: 1, now: { clock }, pause: { clock += 0.1 })
        }
        print("PASS: refused and cancelled quit abort without a signal fallback")

        var rawWasRequested = false
        try expectFailure("no normal app-quit interface") {
            _ = try prepareQuitTargets(
                processes: [AppProcess(pid: 104, executablePath: literal)], matcher: matcher,
                application: { _ in rawWasRequested = true; return nil }
            )
        }
        try expect(rawWasRequested, "Raw process must be classified before any quit request")
        try quitNormally(targets: [], timeout: 1, now: { clock }, pause: { clock += 0.1 })
        print("PASS: raw executable refusal and empty target list")

        // Only these two test-owned children are ever terminated by the tests.
        // Real app handles are never requested: libproc inspection is read-only.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macparakeet-quit-test-\(UUID().uuidString)(qa)[literal]")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rawURL = folder.appendingPathComponent("MacParakeet")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: rawURL)
        let raw = Process()
        raw.executableURL = rawURL
        raw.arguments = ["20"]
        try raw.run()
        defer { if raw.isRunning { raw.terminate() }; raw.waitUntilExit() }
        let decoy = Process()
        decoy.executableURL = URL(fileURLWithPath: "/bin/sh")
        decoy.arguments = ["-c", "while :; do :; done", rawURL.path]
        try decoy.run()
        defer { if decoy.isRunning { decoy.terminate() }; decoy.waitUntilExit() }
        let children = try processSnapshot().filter { $0.pid == raw.processIdentifier || $0.pid == decoy.processIdentifier }
        let rawMatcher = try AppExecutableMatcher(paths: [rawURL.path])
        try expect(children.contains { $0.pid == raw.processIdentifier && rawMatcher.matches($0.executablePath) }, "libproc must see raw literal executable")
        try expect(children.contains { $0.pid == decoy.processIdentifier && !rawMatcher.matches($0.executablePath) }, "libproc must ignore target path in unrelated arguments")
        try expectFailure("no normal app-quit interface") {
            _ = try prepareQuitTargets(processes: children, matcher: rawMatcher, application: registeredApplication)
        }
        try expect(raw.isRunning && decoy.isRunning, "Inspection/refusal must leave both children alive")
        print("PASS: real synthetic raw executable refused; argv decoy untouched")
    }
}
