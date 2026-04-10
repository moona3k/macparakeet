import Foundation
import OSLog

// MARK: - Protocol

public protocol TelemetryServiceProtocol: Sendable {
    func send(_ event: TelemetryEventSpec)
    func flush() async
    func flushForTermination()
}

// MARK: - Implementation

public final class TelemetryService: TelemetryServiceProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "Telemetry")
    private let lock = NSLock()
    private var queue: [TelemetryEvent] = []
    private var flushTimer: Timer?
    private var lifecycleObserver: NSObjectProtocol?

    private let baseURL: URL
    private let session: URLSession
    private let sessionId: String
    private let sessionStartedAt: Date
    private let appVer: String
    private let osVer: String
    private let locale: String?
    private let chip: String
    private let isEnabled: () -> Bool

    static let maxQueueSize = 200
    static let flushThreshold = 50
    static let flushInterval: TimeInterval = 60
    static let maxBatchSize = 100
    static let terminationFlushMaxWait: TimeInterval = 0.4
    static let terminationRequestTimeout: TimeInterval = 0.3

    /// Events that must be flushed immediately (not batched in memory).
    private static let immediateEvents: Set<TelemetryEventName> = [
        .telemetryOptedOut,
        .onboardingCompleted,
        .licenseActivated,
        .licenseActivationFailed,
        .trialStarted,
        .trialExpired,
        .purchaseStarted,
        .restoreAttempted,
        .restoreSucceeded,
        .restoreFailed,
        .appQuit,
        .crashOccurred,
    ]

    public init(
        baseURL: URL? = nil,
        session: URLSession = .shared,
        isEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "telemetryEnabled") as? Bool ?? true
        }
    ) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let envURL = ProcessInfo.processInfo.environment["MACPARAKEET_TELEMETRY_URL"],
                  let url = URL(string: envURL) {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "https://macparakeet.com/api")!
        }
        self.session = session
        self.isEnabled = isEnabled
        self.sessionId = UUID().uuidString
        self.sessionStartedAt = Date()

        let info = SystemInfo.current
        self.appVer = info.appVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        self.osVer = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        self.locale = Locale.current.identifier
        self.chip = info.chipType

        startTimer()
        registerLifecycleObservers()
    }

    deinit {
        flushTimer?.invalidate()
        if let lifecycleObserver {
            NotificationCenter.default.removeObserver(lifecycleObserver)
        }
    }

    public func send(_ event: TelemetryEventSpec) {
        guard isEnabled() || event.name == .telemetryOptedOut else { return }

        let telemetryEvent = makeTelemetryEvent(from: event)

        let shouldFlush: Bool
        lock.lock()
        queue.append(telemetryEvent)
        if queue.count > Self.maxQueueSize {
            queue.removeFirst(queue.count - Self.maxQueueSize)
        }
        shouldFlush = queue.count >= Self.flushThreshold || Self.immediateEvents.contains(event.name)
        lock.unlock()

        if shouldFlush {
            Task { await flush() }
        }
    }

    public func flush() async {
        let events = takeQueuedEvents()
        guard !events.isEmpty else { return }
        let failedEvents = await sendBatches(events, using: session, timeoutInterval: 10)
        requeueFailedEvents(failedEvents)
    }

    // MARK: - Internal (for testing)

    var pendingEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    // MARK: - Private

    private func takeQueuedEvents() -> [TelemetryEvent] {
        lock.lock()
        let events = queue
        queue.removeAll()
        lock.unlock()
        return events
    }

    private func requeueFailedEvents(_ events: [TelemetryEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        queue.insert(contentsOf: events, at: 0)
        if queue.count > Self.maxQueueSize {
            queue.removeLast(queue.count - Self.maxQueueSize)
        }
        lock.unlock()
    }

    private func makeTelemetryEvent(from event: TelemetryEventSpec) -> TelemetryEvent {
        TelemetryEvent(
            spec: event,
            appVer: appVer,
            osVer: osVer,
            locale: locale,
            chip: chip,
            session: sessionId
        )
    }

    private func startTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { await self.flush() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.flushTimer = timer
        }
    }

    private func registerLifecycleObservers() {
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flushForTermination()
        }
    }

    public func flushForTermination() {
        lock.lock()
        if isEnabled() {
            queue.append(makeTelemetryEvent(
                from: .appQuit(sessionDurationSeconds: Date().timeIntervalSince(sessionStartedAt))
            ))
        }
        let events = queue
        queue.removeAll()
        lock.unlock()

        guard !events.isEmpty else { return }
        let completion = DispatchSemaphore(value: 0)
        let session = self.session
        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                completion.signal()
                return
            }
            _ = await self.sendBatches(events, using: session, timeoutInterval: Self.terminationRequestTimeout)
            completion.signal()
        }
        _ = completion.wait(timeout: .now() + Self.terminationFlushMaxWait)
    }

    private func sendBatches(
        _ events: [TelemetryEvent],
        using session: URLSession,
        timeoutInterval: TimeInterval
    ) async -> [TelemetryEvent] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let url = baseURL.appendingPathComponent("telemetry")
        var failedEvents: [TelemetryEvent] = []

        for batchStart in stride(from: 0, to: events.count, by: Self.maxBatchSize) {
            let batchEnd = min(batchStart + Self.maxBatchSize, events.count)
            let batchEvents = Array(events[batchStart..<batchEnd])
            let payload = TelemetryPayload(events: batchEvents)

            guard let body = try? encoder.encode(payload) else {
                logger.error("Failed to encode telemetry payload")
                failedEvents.append(contentsOf: batchEvents)
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = timeoutInterval

            let sent = await sendAsync(request, using: session)
            if !sent {
                failedEvents.append(contentsOf: batchEvents)
            }
        }

        return failedEvents
    }

    private func sendAsync(_ request: URLRequest, using session: URLSession) async -> Bool {
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                logger.warning("Telemetry server returned \(http.statusCode)")
                return false
            }
            return true
        } catch {
            logger.debug("Telemetry flush failed: \(error.localizedDescription)")
            return false
        }
    }

}

// MARK: - Static Convenience

/// Ergonomic static wrapper for fire-and-forget telemetry.
///
/// Usage:
/// ```swift
/// Telemetry.send(.dictationCompleted(durationSeconds: 12.5, wordCount: 84, mode: .persistent))
/// Telemetry.send(.appLaunched)
/// ```
public enum Telemetry {
    private final class ServiceStore: @unchecked Sendable {
        private let lock = NSLock()
        private var service: TelemetryServiceProtocol?

        func set(_ service: TelemetryServiceProtocol) {
            lock.lock()
            self.service = service
            lock.unlock()
        }

        func get() -> TelemetryServiceProtocol? {
            lock.lock()
            defer { lock.unlock() }
            return service
        }
    }

    private static let serviceStore = ServiceStore()

    private static func configuredService() -> TelemetryServiceProtocol? {
        serviceStore.get()
    }

    public static func configure(_ service: TelemetryServiceProtocol) {
        serviceStore.set(service)
    }

    public static func send(_ event: TelemetryEventSpec) {
        configuredService()?.send(event)
    }

    public static func flush() async {
        await configuredService()?.flush()
    }

    public static func flushForTermination() {
        configuredService()?.flushForTermination()
    }
}

// MARK: - No-Op Implementation

public final class NoOpTelemetryService: TelemetryServiceProtocol {
    public init() {}
    public func send(_ event: TelemetryEventSpec) {}
    public func flush() async {}
    public func flushForTermination() {}
}
