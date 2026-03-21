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
        await sendBatches(events, using: session, timeoutInterval: 10, waitTimeout: nil)
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
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: .main
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

        let bgSession = URLSession(
            configuration: .ephemeral,
            delegate: nil,
            delegateQueue: OperationQueue()
        )
        sendBatchesSynchronously(events, using: bgSession, timeoutInterval: 3, waitTimeout: 3)
    }

    private func sendBatches(
        _ events: [TelemetryEvent],
        using session: URLSession,
        timeoutInterval: TimeInterval,
        waitTimeout: TimeInterval?
    ) async {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let url = baseURL.appendingPathComponent("telemetry")

        for batchStart in stride(from: 0, to: events.count, by: Self.maxBatchSize) {
            let batchEnd = min(batchStart + Self.maxBatchSize, events.count)
            let payload = TelemetryPayload(events: Array(events[batchStart..<batchEnd]))

            guard let body = try? encoder.encode(payload) else {
                logger.error("Failed to encode telemetry payload")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = timeoutInterval

            if let waitTimeout {
                sendSynchronously(request, using: session, waitTimeout: waitTimeout)
            } else {
                await sendAsync(request, using: session)
            }
        }
    }

    private func sendAsync(_ request: URLRequest, using session: URLSession) async {
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                logger.warning("Telemetry server returned \(http.statusCode)")
            }
        } catch {
            logger.debug("Telemetry flush failed: \(error.localizedDescription)")
        }
    }

    private func sendSynchronously(
        _ request: URLRequest,
        using session: URLSession,
        waitTimeout: TimeInterval
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                self.logger.debug("Telemetry termination flush failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.logger.warning("Telemetry server returned \(http.statusCode)")
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + waitTimeout)
    }

    private func sendBatchesSynchronously(
        _ events: [TelemetryEvent],
        using session: URLSession,
        timeoutInterval: TimeInterval,
        waitTimeout: TimeInterval
    ) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let url = baseURL.appendingPathComponent("telemetry")

        for batchStart in stride(from: 0, to: events.count, by: Self.maxBatchSize) {
            let batchEnd = min(batchStart + Self.maxBatchSize, events.count)
            let payload = TelemetryPayload(events: Array(events[batchStart..<batchEnd]))

            guard let body = try? encoder.encode(payload) else {
                logger.error("Failed to encode telemetry payload")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = timeoutInterval

            sendSynchronously(request, using: session, waitTimeout: waitTimeout)
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
    private static let lock = NSLock()
    private static var _service: TelemetryServiceProtocol?

    private static func configuredService() -> TelemetryServiceProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return _service
    }

    public static func configure(_ service: TelemetryServiceProtocol) {
        lock.lock()
        _service = service
        lock.unlock()
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
