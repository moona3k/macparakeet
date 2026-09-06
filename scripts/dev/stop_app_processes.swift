import AppKit
import Darwin

struct ShutdownError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct AppProcess {
    let pid: pid_t
    let executablePath: String
}

struct AppExecutableMatcher {
    let paths: Set<String>

    init(paths: [String]) throws {
        guard !paths.isEmpty else {
            throw ShutdownError("At least one MacParakeet executable path is required.")
        }
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ShutdownError("Executable paths must be absolute.")
        }
        guard paths.allSatisfy({ URL(fileURLWithPath: $0).lastPathComponent == "MacParakeet" }) else {
            throw ShutdownError("Expected MacParakeet executable paths.")
        }
        self.paths = Set(paths.map(Self.canonicalPath))
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    var executableNames: Set<String> {
        Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }).union(["MacParakeet"])
    }

    func matches(_ executablePath: String) -> Bool {
        let path = Self.canonicalPath(executablePath)
        // Other worktrees may also have a Dev bundle running. Match its literal
        // executable path components, never a command-line argument or regex.
        return paths.contains(path)
            || path.hasSuffix("/MacParakeet-Dev.app/Contents/MacOS/MacParakeet")
    }
}

/// Validate the CLI contract before any process enumeration or quit request.
struct ShutdownRequest {
    let timeout: TimeInterval
    let matcher: AppExecutableMatcher

    init(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw ShutdownError("Expected a positive timeout and at least one absolute executable path.")
        }
        guard let timeout = TimeInterval(arguments[0]), timeout > 0, timeout.isFinite else {
            throw ShutdownError("Expected a positive timeout followed by absolute executable paths.")
        }
        self.timeout = timeout
        matcher = try AppExecutableMatcher(paths: Array(arguments.dropFirst()))
    }
}

struct QuitTarget {
    let pid: pid_t
    let requestQuit: () -> Bool
    let hasExited: () -> Bool
}

func quitNormally(
    targets: [QuitTarget], timeout: TimeInterval,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    pause: () -> Void = { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
) throws {
    let deadline = now() + timeout
    for target in targets where !target.hasExited() {
        guard target.requestQuit() || target.hasExited() else {
            throw ShutdownError("Normal quit request failed for PID \(target.pid). Quit MacParakeet manually, then retry.")
        }
    }
    while targets.contains(where: { !$0.hasExited() }) {
        guard now() < deadline else {
            throw ShutdownError("MacParakeet is still open after \(timeout)s. Complete or cancel its quit dialog, then retry. No process was force-terminated.")
        }
        pause()
    }
}

func processSnapshot(executableNames: Set<String> = ["MacParakeet"]) throws -> [AppProcess] {
    // libproc returns executable paths independently of argv, including raw
    // unbundled processes that NSWorkspace.runningApplications can omit.
    for _ in 0..<3 {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard size > 0 else { throw ShutdownError("Cannot inspect current-user processes.") }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 128)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, capacity)
        guard bytes > 0 else { throw ShutdownError("Cannot inspect current-user processes.") }
        if bytes >= capacity { continue }
        return try pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }.compactMap { pid in
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                return AppProcess(pid: pid, executablePath: String(cString: buffer))
            }
            // A process can exit between enumeration and inspection. Any other
            // failure must prevent rebuilding a potentially running executable.
            let pathError = errno
            if pathError == ESRCH || (kill(pid, 0) == -1 && errno == ESRCH) { return nil }
            // macOS can hide paths for unrelated protected processes. Check
            // the kernel executable name before treating that as a blocker;
            // include canonical executable names in case a supplied path is a symlink.
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size) {
                let name = withUnsafePointer(to: &info.pbi_comm) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if info.pbi_status == UInt32(SZOMB) || !executableNames.contains(name) { return nil }
            }
            throw ShutdownError("Cannot inspect executable for PID \(pid) (errno \(pathError)).")
        }
    }
    throw ShutdownError("Process list kept changing during inspection; retry the build.")
}

func prepareQuitTargets(
    processes: [AppProcess], matcher: AppExecutableMatcher,
    application: (AppProcess) -> QuitTarget?
) throws -> [QuitTarget] {
    try processes.filter { matcher.matches($0.executablePath) }.map { process in
        guard let target = application(process) else {
            throw ShutdownError("MacParakeet PID \(process.pid) has no normal app-quit interface (\(process.executablePath)). Quit it manually before rebuilding.")
        }
        return target
    }
}

func registeredApplication(_ process: AppProcess) -> QuitTarget? {
    guard let app = NSRunningApplication(processIdentifier: process.pid),
          app.bundleURL != nil,
          let executableURL = app.executableURL,
          AppExecutableMatcher.canonicalPath(executableURL.path)
            == AppExecutableMatcher.canonicalPath(process.executablePath)
    else { return nil }
    return QuitTarget(pid: process.pid, requestQuit: { app.terminate() }, hasExited: { app.isTerminated })
}

#if !LAUNCHER_TESTS
@main
struct StopMacParakeet {
    static func main() {
        do {
            let request = try ShutdownRequest(arguments: Array(CommandLine.arguments.dropFirst()))
            let matcher = request.matcher
            let targets = try prepareQuitTargets(processes: processSnapshot(executableNames: matcher.executableNames), matcher: matcher, application: registeredApplication)
            try quitNormally(targets: targets, timeout: request.timeout)
            // A new app may have launched during the quit dialog or finalization.
            // Refuse to build rather than silently miss it or interrupt it again.
            guard try !processSnapshot(executableNames: matcher.executableNames).contains(where: { matcher.matches($0.executablePath) }) else {
                throw ShutdownError("A MacParakeet executable is still running or restarted; quit it and retry.")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error) Build aborted before modifying the bundle.\n".utf8))
            exit(1)
        }
    }
}
#endif
