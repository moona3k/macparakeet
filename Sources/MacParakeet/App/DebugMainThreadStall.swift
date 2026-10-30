#if DEBUG
import Foundation

/// DEBUG-only QA hook for #1142: blocks the main thread on purpose so testers
/// can confirm typing in other apps stays smooth while MacParakeet's UI is
/// stuck. Launch with
/// `open MacParakeet-Dev.app --env MACPARAKEET_DEBUG_MAIN_STALL_MS=500`
/// to stall for 500 ms every two seconds.
@MainActor
enum DebugMainThreadStall {
    static let environmentKey = "MACPARAKEET_DEBUG_MAIN_STALL_MS"
    private static var timer: Timer?

    static func stallMilliseconds(environment: [String: String]) -> Int? {
        guard let raw = environment[environmentKey], let ms = Int(raw), ms > 0 else { return nil }
        return min(ms, 5_000)
    }

    static func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard timer == nil, let ms = stallMilliseconds(environment: environment) else { return }
        NSLog("MacParakeet DEBUG: stalling the main thread for %d ms every 2 s", ms)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Thread.sleep(forTimeInterval: Double(ms) / 1_000)
        }
    }
}
#endif
