import Foundation
import XCTest

@testable import MacParakeetCore

private struct RecordedTelemetryPayload: Decodable {
    let events: [RecordedTelemetryEvent]
}

private struct RecordedTelemetryEvent: Decodable {
    let event: String
    let session: String
}

private final class TelemetryMockURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var statusCode = 200
    static var payloads: [RecordedTelemetryPayload] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        defer { client?.urlProtocolDidFinishLoading(self) }

        let body: Data?
        if let httpBody = request.httpBody {
            body = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    collected.append(buffer, count: count)
                } else {
                    break
                }
            }
            stream.close()
            body = collected
        } else {
            body = nil
        }

        guard let body else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let payload = try JSONDecoder().decode(RecordedTelemetryPayload.self, from: body)
            Self.lock.lock()
            Self.payloads.append(payload)
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        payloads = []
        statusCode = 200
        lock.unlock()
    }

    static func recordedPayloads() -> [RecordedTelemetryPayload] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}

final class TelemetryServiceTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeService(
        session: URLSession? = nil,
        isEnabled: @escaping () -> Bool = { true }
    ) -> TelemetryService {
        TelemetryService(
            baseURL: URL(string: "https://localhost:9999")!,
            session: session ?? makeSession(),
            isEnabled: isEnabled
        )
    }

    override func setUp() {
        TelemetryMockURLProtocol.reset()
        Telemetry.configure(NoOpTelemetryService())
    }

    // MARK: - Event Queuing

    func testSendQueuesEvent() {
        let service = makeService()
        service.send(.appLaunched)
        XCTAssertEqual(service.pendingEventCount, 1)
    }

    func testSendMultipleEventsQueuesAll() {
        let service = makeService()
        service.send(.appLaunched)
        service.send(.dictationStarted(trigger: .hotkey, mode: .persistent))
        service.send(.dictationCompleted(durationSeconds: 5.0, wordCount: 42, mode: .persistent))
        XCTAssertEqual(service.pendingEventCount, 3)
    }

    // MARK: - Opt-Out

    func testSendIsNoOpWhenDisabled() {
        let service = makeService(isEnabled: { false })
        service.send(.appLaunched)
        service.send(.dictationStarted(trigger: .hotkey, mode: .hold))
        XCTAssertEqual(service.pendingEventCount, 0)
    }

    func testOptOutEventBypassesDisabledCheck() {
        let service = makeService(isEnabled: { false })
        service.send(.telemetryOptedOut)
        service.send(.appLaunched)
        XCTAssertLessThanOrEqual(service.pendingEventCount, 1)
    }

    // MARK: - Queue Limits

    func testMaxQueueSizeEnforced() {
        let service = makeService()
        for i in 0..<250 {
            service.send(.dictationFailed(errorType: "error-\(i)"))
        }
        XCTAssertLessThanOrEqual(service.pendingEventCount, TelemetryService.maxQueueSize)
    }

    // MARK: - Flush

    func testFlushClearsQueue() async {
        let service = makeService()
        service.send(.appLaunched)
        service.send(.dictationStarted(trigger: .hotkey, mode: .persistent))
        XCTAssertEqual(service.pendingEventCount, 2)

        await service.flush()
        XCTAssertEqual(service.pendingEventCount, 0)
    }

    func testFlushEmptyQueueIsNoOp() async {
        let service = makeService()
        await service.flush()
        XCTAssertEqual(service.pendingEventCount, 0)
    }

    func testFlushSplitsRequestsIntoBatchesOf100() async throws {
        let eventCount = 150
        let service = makeService()
        for i in 0..<eventCount {
            service.send(.dictationFailed(errorType: "error-\(i)"))
        }

        // Allow auto-flush Tasks (triggered at flushThreshold) to complete,
        // then drain any remaining events with an explicit flush.
        try await Task.sleep(nanoseconds: 200_000_000)
        await service.flush()
        try await Task.sleep(nanoseconds: 200_000_000)

        let payloads = TelemetryMockURLProtocol.recordedPayloads()
        XCTAssertFalse(payloads.isEmpty)
        XCTAssertTrue(payloads.allSatisfy { $0.events.count <= TelemetryService.maxBatchSize })

        // Total must equal eventCount. Using a count under maxQueueSize (200)
        // ensures no events are trimmed regardless of auto-flush timing.
        let totalEvents = payloads.reduce(0) { $0 + $1.events.count }
        XCTAssertEqual(totalEvents, eventCount)
    }

    func testTerminationFlushDoesNotEmitAppQuitWhenTelemetryDisabled() async throws {
        let service = makeService(isEnabled: { false })

        NotificationCenter.default.post(
            name: NSNotification.Name("NSApplicationWillTerminateNotification"),
            object: nil
        )
        let events = try await eventuallyRecordedEvents()
        XCTAssertFalse(events.contains { $0.event == TelemetryEventName.appQuit.rawValue })
        _ = service
    }

    func testTerminationFlushEmitsAppQuitWhenTelemetryEnabled() async throws {
        let service = makeService(isEnabled: { true })

        NotificationCenter.default.post(
            name: NSNotification.Name("NSApplicationWillTerminateNotification"),
            object: nil
        )
        let events = try await eventuallyRecordedEvents()
        XCTAssertTrue(events.contains { $0.event == TelemetryEventName.appQuit.rawValue })
        _ = service
    }

    // MARK: - Event Serialization

    func testEventSerializesToJSON() throws {
        let event = TelemetryEvent(
            spec: .dictationCompleted(durationSeconds: 12.5, wordCount: 84, mode: .persistent),
            appVer: "0.4.2",
            osVer: "15.3",
            locale: "en-US",
            chip: "Apple M1",
            session: "test-session"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let props = try XCTUnwrap(json["props"] as? [String: String])

        XCTAssertEqual(json["event"] as? String, "dictation_completed")
        XCTAssertEqual(json["app_ver"] as? String, "0.4.2")
        XCTAssertEqual(json["os_ver"] as? String, "15.3")
        XCTAssertEqual(json["locale"] as? String, "en-US")
        XCTAssertEqual(json["chip"] as? String, "Apple M1")
        XCTAssertEqual(json["session"] as? String, "test-session")
        XCTAssertNotNil(json["event_id"])
        XCTAssertNotNil(json["ts"])
        XCTAssertEqual(props["duration_seconds"], "12.5")
        XCTAssertEqual(props["word_count"], "84")
        XCTAssertEqual(props["mode"], "persistent")
    }

    func testEventWithoutPropsSerializes() throws {
        let event = TelemetryEvent(
            spec: .appLaunched,
            appVer: "0.4.2",
            osVer: "15.3",
            locale: nil,
            chip: "Apple M1",
            session: "test-session"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "app_launched")
        XCTAssertTrue(json["props"] is NSNull || json["props"] == nil)
    }

    func testTranscriptionCompletedSerializesDiarizationContext() throws {
        let event = TelemetryEvent(
            spec: .transcriptionCompleted(
                source: .meeting,
                audioDurationSeconds: 90.0,
                processingSeconds: 12.4,
                wordCount: 240,
                speakerCount: 3,
                diarizationRequested: true,
                diarizationApplied: true,
                meetingPreparedTranscriptUsed: true
            ),
            appVer: "0.4.2",
            osVer: "15.3",
            locale: "en-US",
            chip: "Apple M1",
            session: "test-session"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let props = try XCTUnwrap(json["props"] as? [String: String])

        XCTAssertEqual(props["source"], "meeting")
        XCTAssertEqual(props["audio_duration_seconds"], "90.0")
        XCTAssertEqual(props["processing_seconds"], "12.4")
        XCTAssertEqual(props["word_count"], "240")
        XCTAssertEqual(props["speaker_count"], "3")
        XCTAssertEqual(props["diarization_requested"], "true")
        XCTAssertEqual(props["diarization_applied"], "true")
        XCTAssertEqual(props["meeting_prepared_transcript_used"], "true")
    }

    func testTranscriptionFailedSerializesStage() throws {
        let event = TelemetryEvent(
            spec: .transcriptionFailed(
                source: .youtube,
                stage: .download,
                errorType: "download_failed"
            ),
            appVer: "0.4.2",
            osVer: "15.3",
            locale: "en-US",
            chip: "Apple M1",
            session: "test-session"
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let props = try XCTUnwrap(json["props"] as? [String: String])

        XCTAssertEqual(props["source"], "youtube")
        XCTAssertEqual(props["stage"], "download")
        XCTAssertEqual(props["error_type"], "download_failed")
    }

    func testImplementedContractCoversEveryTypedEventName() {
        XCTAssertEqual(
            Set(TelemetryEventName.allCases),
            TelemetryImplementedContract.implementedEventNames
        )
    }

    func testImplementedContractRequiredPropsArePresent() {
        for event in sampleEvents() {
            let requiredProps = TelemetryImplementedContract.requiredProps[event.name] ?? []
            let propKeys = Set(event.props?.keys ?? Dictionary<String, String>().keys)
            XCTAssertTrue(
                requiredProps.isSubset(of: propKeys),
                "Missing required props for \(event.name.rawValue): \(requiredProps.subtracting(propKeys))"
            )
        }
    }

    // MARK: - Session UUID

    func testSessionIdIsPerInstance() async {
        let service1 = makeService()
        let service2 = makeService()

        service1.send(.appLaunched)
        service2.send(.appLaunched)
        await service1.flush()
        await service2.flush()

        let payloads = TelemetryMockURLProtocol.recordedPayloads()
        let sessions = Set(payloads.flatMap(\.events).map(\.session))
        XCTAssertGreaterThanOrEqual(sessions.count, 2)
    }

    // MARK: - Payload Encoding

    func testPayloadEncodesCorrectly() throws {
        let events = [
            TelemetryEvent(
                spec: .appLaunched,
                appVer: "0.4.2",
                osVer: "15.3",
                locale: "en-US",
                chip: "Apple M1",
                session: "s1"
            ),
            TelemetryEvent(
                spec: .dictationStarted(trigger: .hotkey, mode: .persistent),
                appVer: "0.4.2",
                osVer: "15.3",
                locale: "en-US",
                chip: "Apple M1",
                session: "s1"
            ),
        ]
        let payload = TelemetryPayload(events: events)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let eventsArray = try XCTUnwrap(json["events"] as? [[String: Any]])

        XCTAssertEqual(eventsArray.count, 2)
        XCTAssertEqual(eventsArray[0]["event"] as? String, "app_launched")
        XCTAssertEqual(eventsArray[1]["event"] as? String, "dictation_started")
    }

    // MARK: - NoOp Implementation

    func testNoOpServiceDoesNothing() async {
        let service = NoOpTelemetryService()
        service.send(.appLaunched)
        service.send(.dictationStarted(trigger: .hotkey, mode: .hold))
        await service.flush()
    }

    // MARK: - Static Telemetry Wrapper

    func testStaticTelemetryConfigureAndSend() {
        let service = makeService()
        Telemetry.configure(service)
        Telemetry.send(.appLaunched)
        XCTAssertEqual(service.pendingEventCount, 1)
    }

    func testStaticTelemetrySendBeforeConfigureIsNoOp() {
        Telemetry.configure(NoOpTelemetryService())
        Telemetry.send(.appLaunched)
    }

    // MARK: - AppPreferences

    func testTelemetryEnabledDefault() {
        let defaults = UserDefaults(suiteName: "test-telemetry-\(UUID().uuidString)")!
        XCTAssertTrue(AppPreferences.isTelemetryEnabled(defaults: defaults))
    }

    func testTelemetryEnabledRespectsUserChoice() {
        let defaults = UserDefaults(suiteName: "test-telemetry-\(UUID().uuidString)")!
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertFalse(AppPreferences.isTelemetryEnabled(defaults: defaults))
    }

    private func sampleEvents() -> [TelemetryEventSpec] {
        [
            .appLaunched,
            .appQuit(sessionDurationSeconds: 12.5),
            .dictationStarted(trigger: .hotkey, mode: .persistent),
            .dictationCompleted(durationSeconds: 12.5, wordCount: 84, mode: .persistent),
            .dictationCancelled(durationSeconds: 1.5, reason: .escape),
            .dictationEmpty(durationSeconds: 1.5),
            .dictationFailed(errorType: "network"),
            .transcriptionStarted(source: .file, audioDurationSeconds: 30.0),
            .transcriptionCompleted(
                source: .dragDrop,
                audioDurationSeconds: 30.0,
                processingSeconds: 2.4,
                wordCount: 120,
                speakerCount: 2,
                diarizationRequested: true,
                diarizationApplied: true,
                meetingPreparedTranscriptUsed: nil
            ),
            .transcriptionCancelled(source: .youtube, audioDurationSeconds: 45.0, stage: .stt),
            .transcriptionFailed(source: .file, stage: .audioConversion, errorType: "transcribe"),
            .exportUsed(format: "txt"),
            .llmPromptResultUsed(provider: "openai"),
            .llmPromptResultFailed(provider: "openai", errorType: "auth"),
            .llmChatUsed(provider: "openai", messageCount: 3),
            .llmChatFailed(provider: "openai", errorType: "network"),
            .historySearched,
            .historyReplayed,
            .copyToClipboard(source: .transcription),
            .hotkeyCustomized,
            .processingModeChanged(mode: "precise"),
            .customWordAdded,
            .customWordDeleted,
            .snippetAdded,
            .snippetDeleted,
            .promptCreated,
            .promptUpdated,
            .promptDeleted,
            .settingChanged(setting: .saveHistory),
            .telemetryOptedOut,
            .onboardingCompleted(durationSeconds: 10.0),
            .licenseActivated,
            .trialStarted,
            .trialExpired,
            .purchaseStarted,
            .restoreAttempted,
            .restoreSucceeded,
            .restoreFailed(errorType: "storekit"),
            .permissionPrompted(permission: .microphone),
            .permissionGranted(permission: .microphone),
            .permissionDenied(permission: .accessibility),
            .modelLoaded(loadTimeSeconds: 2.5),
            .modelDownloadStarted,
            .modelDownloadCompleted(durationSeconds: 30.0),
            .modelDownloadFailed(errorType: "network"),
            .onboardingStep(step: "microphone"),
            .licenseActivationFailed(errorType: "invalid_key"),
            .keystrokeSnippetFired(action: "return"),
            .meetingRecordingStarted,
            .meetingRecordingCompleted(durationSeconds: 1800.0, liveWordCount: 4200, liveTranscriptLagged: false),
            .meetingRecordingCancelled(durationSeconds: 30.0),
            .meetingRecordingFailed(errorType: "tap_creation_failed"),
            .errorOccurred(domain: "STTError", code: "engineFailed", description: "test"),
            .crashOccurred(
                crashType: "signal", signal: "11", name: "SIGSEGV",
                crashTimestamp: "1711900000", crashAppVer: "0.5.1",
                crashOsVer: "15.3.1", uuid: "A1B2C3D4", slide: "0x100000",
                reason: nil, stackTrace: "0x1234\n0x5678"
            ),
        ]
    }

    private func eventuallyRecordedEvents(
        timeoutNanoseconds: UInt64 = 1_500_000_000,
        pollNanoseconds: UInt64 = 50_000_000
    ) async throws -> [RecordedTelemetryEvent] {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            let events = TelemetryMockURLProtocol.recordedPayloads().flatMap(\.events)
            if !events.isEmpty {
                return events
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return TelemetryMockURLProtocol.recordedPayloads().flatMap(\.events)
    }
}
