import Foundation
import OSLog
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Protocol

public protocol TelemetryServiceProtocol: Sendable {
    func send(_ event: TelemetryEventSpec)
    @discardableResult
    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool
    func clearQueue()
    func flush() async
    func flushForTermination()
}

private actor TelemetryFlushGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Bridges structured task cancellation to the synchronously admitted URL task.
private final class TelemetryRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func install(_ task: URLSessionDataTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

// MARK: - Implementation

public final class TelemetryService: TelemetryServiceProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "Telemetry")
    private let lock = NSLock()
    private let flushGate = TelemetryFlushGate()
    private var queue: [TelemetryEvent] = []
    // Clearing consent invalidates snapshots already removed from the queue,
    // including retries and batches that have not been admitted for dispatch.
    private var queueGeneration: UInt64 = 0
    private var automaticFlushPending = false
    private var nextRetryAt: Date?
    private var consecutiveFailures = 0
    // Configured before use in deterministic transport tests.
    var now: @Sendable () -> Date = { Date() }
    var retryJitter: @Sendable () -> Double = { Double.random(in: 0.8...1.2) }

    private struct BatchResult {
        var retryEvents: [TelemetryEvent] = []
        var rejectedIDs: Set<String> = []
    }

    private enum DeliveryResult {
        case delivered
        case discarded
        case rejected(status: Int)
        case retry(status: Int, after: TimeInterval?)
    }
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
    private let gitCommit: String
    private let buildNumber: String
    private let surface: String
    private let isEnabled: () -> Bool
    private let isTransportEligible: () -> Bool
    private let requestTimeoutInterval: TimeInterval

    static let maxQueueSize = 200
    static let flushThreshold = 50
    static let flushInterval: TimeInterval = 60
    static let maxBatchSize = 100
    static let terminationFlushMaxWait: TimeInterval = 0.4
    static let terminationRequestTimeout: TimeInterval = 0.3

    private static var appWillTerminateNotification: Notification.Name {
        #if canImport(AppKit)
        NSApplication.willTerminateNotification
        #else
        Notification.Name("NSApplicationWillTerminateNotification")
        #endif
    }

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
        requestTimeoutInterval: TimeInterval = 10,
        surface: String = "gui",
        appVersionOverride: String? = nil,
        isTransportEligible: (() -> Bool)? = nil,
        isEnabled: (() -> Bool)? = nil
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
        self.isEnabled = isEnabled ?? TelemetryPolicy.currentGUIEnabled
        // Explicit consent injection is used by the CLI and isolated clients;
        // those callers already select their policy rather than the GUI defaults.
        self.isTransportEligible = isTransportEligible
            ?? (isEnabled == nil ? TelemetryPolicy.currentGUITransportEligible : { true })
        self.requestTimeoutInterval = requestTimeoutInterval
        self.sessionId = UUID().uuidString
        self.sessionStartedAt = Date()

        let info = SystemInfo.current
        // CLI executables have no Info.plist, so Bundle.main returns synthesized
        // values (e.g. an SDK marker like "16.0"). The CLI passes its own version
        // explicitly so it doesn't pollute GUI version-adoption metrics.
        self.appVer = appVersionOverride ?? info.appVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        self.osVer = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        self.locale = Locale.current.identifier
        self.chip = info.chipType
        self.gitCommit = Observability.sanitizedGitCommit(info.gitCommit)
        self.buildNumber = Observability.sanitizedBuildNumber(info.buildNumber)
        self.surface = surface

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
        guard let generation = queueGeneration(ifAllowed: event.name) else { return }

        let telemetryEvent = makeTelemetryEvent(from: event)

        let shouldFlush: Bool
        lock.lock()
        guard generation == queueGeneration,
            isTransportEligible(), isEnabled() || event.name == .telemetryOptedOut
        else {
            lock.unlock()
            return
        }
        queue.append(telemetryEvent)
        if queue.count > Self.maxQueueSize {
            let dropped = queue.count - Self.maxQueueSize
            queue.removeFirst(dropped)
            logger.info("telemetry_transport outcome=queue_full dropped_count=\(dropped, privacy: .public)")
        }
        shouldFlush = queue.count >= Self.flushThreshold || Self.immediateEvents.contains(event.name)
        lock.unlock()

        if shouldFlush { scheduleAutomaticFlush() }
    }

    @discardableResult
    public func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        guard let generation = queueGeneration(ifAllowed: event.name) else { return true }

        let telemetryEvent = makeTelemetryEvent(from: event)

        await flushGate.enter()
        guard enqueue(telemetryEvent, generation: generation) else {
            await flushGate.leave()
            return true  // Intentionally discarded by an opt-out while waiting.
        }
        let failedEventIds = await flushQueuedEvents()
        await flushGate.leave()

        return !failedEventIds.contains(telemetryEvent.eventId)
    }

    public func flush() async {
        await flushGate.enter()
        _ = await flushQueuedEvents()
        await flushGate.leave()
    }

    public func clearQueue() {
        lock.lock()
        queueGeneration &+= 1
        nextRetryAt = nil
        consecutiveFailures = 0
        queue.removeAll()
        lock.unlock()
    }

    private func scheduleAutomaticFlush() {
        let scheduled = lock.withLock {
            guard !automaticFlushPending else { return false }
            automaticFlushPending = true
            return true
        }
        guard scheduled else { return }
        Task {
            await flush()
            let needsAnotherFlush = lock.withLock {
                automaticFlushPending = false
                guard nextRetryAt.map({ now() >= $0 }) ?? true else { return false }
                return queue.count >= Self.flushThreshold || queue.contains {
                    Self.immediateEvents.contains(TelemetryEventName(rawValue: $0.event) ?? .appLaunched)
                }
            }
            if needsAnotherFlush { scheduleAutomaticFlush() }
        }
    }

    private func flushQueuedEvents() async -> Set<String> {
        let deferred = lock.withLock { () -> Set<String>? in
            guard let nextRetryAt, now() < nextRetryAt else { return nil }
            return Set(queue.map(\.eventId))
        }
        if let deferred { return deferred }
        let (events, generation) = takeQueuedEvents()
        guard !events.isEmpty else { return [] }
        let result = await sendBatches(
            events, generation: generation, using: session, timeoutInterval: requestTimeoutInterval
        )
        let retainedFailures = requeueFailedEvents(result.retryEvents, generation: generation)
        return Set(retainedFailures.map(\.eventId)).union(result.rejectedIDs)
    }

    // MARK: - Internal (for testing)

    var pendingEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    // Set before starting a flush in tests to exercise the encoding/admission gap.
    var beforeRequestAdmission: (@Sendable () -> Void)?

    // MARK: - Private

    private func queueGeneration(ifAllowed event: TelemetryEventName) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard isTransportEligible(), isEnabled() || event == .telemetryOptedOut else { return nil }
        return queueGeneration
    }

    private func enqueue(_ event: TelemetryEvent, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == queueGeneration,
            isTransportEligible(), isEnabled() || event.event == TelemetryEventName.telemetryOptedOut.rawValue
        else { return false }
        queue.append(event)
        if queue.count > Self.maxQueueSize {
            let dropped = queue.count - Self.maxQueueSize
            queue.removeFirst(dropped)
            logger.info("telemetry_transport outcome=queue_full dropped_count=\(dropped, privacy: .public)")
        }
        return true
    }

    private func takeQueuedEvents() -> ([TelemetryEvent], UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let events = queue
        queue.removeAll()
        return (events, queueGeneration)
    }

    private func requeueFailedEvents(_ events: [TelemetryEvent], generation: UInt64) -> [TelemetryEvent] {
        guard !events.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard generation == queueGeneration else { return [] }
        let retained = eventsAllowedByConsent(events)
        queue.insert(contentsOf: retained, at: 0)
        if queue.count > Self.maxQueueSize {
            let dropped = queue.count - Self.maxQueueSize
            queue.removeLast(dropped)
            logger.info("telemetry_transport outcome=queue_full dropped_count=\(dropped, privacy: .public)")
        }
        return retained
    }

    /// Called under `lock`; only the final opt-out event may be sent while disabled.
    private func eventsAllowedByConsent(_ events: [TelemetryEvent]) -> [TelemetryEvent] {
        guard isTransportEligible() else { return [] }
        return isEnabled() ? events : events.filter { $0.event == TelemetryEventName.telemetryOptedOut.rawValue }
    }

    private func eventsAllowedForDispatch(_ events: [TelemetryEvent], generation: UInt64) -> [TelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard generation == queueGeneration else { return [] }
        return eventsAllowedByConsent(events)
    }

    private func makeTelemetryEvent(from event: TelemetryEventSpec) -> TelemetryEvent {
        TelemetryEvent(
            spec: event,
            appVer: appVer,
            osVer: osVer,
            locale: locale,
            chip: chip,
            session: sessionId,
            surface: surface,
            gitCommit: gitCommit,
            buildNumber: buildNumber
        )
    }

    private func startTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.scheduleAutomaticFlush()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.flushTimer = timer
        }
    }

    private func registerLifecycleObservers() {
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: Self.appWillTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flushForTermination()
        }
    }

    public func flushForTermination() {
        lock.lock()
        if isTransportEligible(), isEnabled() {
            queue.append(makeTelemetryEvent(
                from: .appQuit(sessionDurationSeconds: Date().timeIntervalSince(sessionStartedAt))
            ))
        }
        let events: [TelemetryEvent]
        if let nextRetryAt, now() < nextRetryAt {
            // Consent permits the final event, but does not bypass server backoff.
            events = []
        } else {
            events = queue
        }
        let generation = queueGeneration
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
            _ = await self.sendBatches(
                events, generation: generation, using: session, timeoutInterval: Self.terminationRequestTimeout
            )
            completion.signal()
        }
        _ = completion.wait(timeout: .now() + Self.terminationFlushMaxWait)
    }

    private func sendBatches(
        _ events: [TelemetryEvent],
        generation: UInt64,
        using session: URLSession,
        timeoutInterval: TimeInterval
    ) async -> BatchResult {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let url = baseURL.appendingPathComponent("telemetry")
        var result = BatchResult()

        for batchStart in stride(from: 0, to: events.count, by: Self.maxBatchSize) {
            let batchEnd = min(batchStart + Self.maxBatchSize, events.count)
            let batchEvents = eventsAllowedForDispatch(Array(events[batchStart..<batchEnd]), generation: generation)
            guard !batchEvents.isEmpty else { continue }
            let payload = TelemetryPayload(events: batchEvents)

            guard let body = try? encoder.encode(payload) else {
                logger.error("Failed to encode telemetry payload")
                result.rejectedIDs.formUnion(batchEvents.map(\.eventId))
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = timeoutInterval

            beforeRequestAdmission?()
            let delivery = await sendAsync(request, events: batchEvents, generation: generation, using: session)
            switch delivery {
            case .discarded:
                logger.debug("telemetry_transport outcome=consent_discarded batch_count=\(batchEvents.count, privacy: .public)")
            case .delivered:
                lock.withLock {
                    if generation == queueGeneration {
                        nextRetryAt = nil
                        consecutiveFailures = 0
                    }
                }
                logger.debug("telemetry_transport outcome=delivered batch_count=\(batchEvents.count, privacy: .public)")
            case .rejected(let status):
                result.rejectedIDs.formUnion(batchEvents.map(\.eventId))
                logger.warning("telemetry_transport outcome=rejected status=\(status, privacy: .public) dropped_count=\(batchEvents.count, privacy: .public)")
            case .retry(let status, let after):
                let delay = lock.withLock { () -> TimeInterval in
                    guard generation == queueGeneration else { return 0 }
                    consecutiveFailures = min(consecutiveFailures + 1, 10)
                    let backoff = min(900, 5 * pow(2, Double(consecutiveFailures - 1)) * retryJitter())
                    let delay = max(backoff, after ?? 0)
                    nextRetryAt = now().addingTimeInterval(delay)
                    return delay
                }
                result.retryEvents.append(contentsOf: batchEvents)
                result.retryEvents.append(contentsOf: events.dropFirst(batchEnd))
                logger.info("telemetry_transport outcome=retry status=\(status, privacy: .public) retry_seconds=\(delay, privacy: .public) pending_count=\(result.retryEvents.count, privacy: .public)")
                return result
            }
        }

        return result
    }

    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    private func sendAsync(
        _ request: URLRequest, events: [TelemetryEvent], generation: UInt64, using session: URLSession
    ) async -> DeliveryResult {
        let cancellation = TelemetryRequestCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Encoding can race with opt-out. Admit and resume under the
                // same lock as clearQueue, so no stale request starts afterward.
                lock.withLock {
                    guard generation == queueGeneration,
                        isTransportEligible(), isEnabled() || events.allSatisfy({ $0.event == TelemetryEventName.telemetryOptedOut.rawValue })
                    else {
                        continuation.resume(returning: DeliveryResult.discarded)
                        return
                    }
                    let task = session.dataTask(with: request) { [now] _, response, error in
                        if error != nil {
                            continuation.resume(returning: DeliveryResult.retry(status: 0, after: nil))
                        } else if let http = response as? HTTPURLResponse {
                            if (200...299).contains(http.statusCode) {
                                continuation.resume(returning: DeliveryResult.delivered)
                            } else if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                                continuation.resume(returning: DeliveryResult.retry(
                                    status: http.statusCode,
                                    after: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now())
                                ))
                            } else {
                                continuation.resume(returning: DeliveryResult.rejected(status: http.statusCode))
                            }
                        } else {
                            continuation.resume(returning: DeliveryResult.retry(status: 0, after: nil))
                        }
                    }
                    cancellation.install(task)
                    task.resume()
                }
            }
        } onCancel: {
            cancellation.cancel()
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

    public static func clearQueue() {
        configuredService()?.clearQueue()
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
    public func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool { true }
    public func clearQueue() {}
    public func flush() async {}
    public func flushForTermination() {}
}
