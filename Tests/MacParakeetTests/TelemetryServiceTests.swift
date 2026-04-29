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

    func testSendAndFlushReturnsTrueWhenDeliverySucceeds() async {
        let service = makeService()

        let delivered = await service.sendAndFlush(.appLaunched)

        XCTAssertTrue(delivered)
        XCTAssertEqual(service.pendingEventCount, 0)
    }

    func testSendAndFlushReturnsFalseAndRequeuesWhenDeliveryFails() async {
        TelemetryMockURLProtocol.statusCode = 500
        let service = makeService()

        let delivered = await service.sendAndFlush(.appLaunched)

        XCTAssertFalse(delivered)
        XCTAssertEqual(service.pendingEventCount, 1)
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

    func testErrorOccurredDescriptionIsSanitizedAndTruncated() throws {
        let event = TelemetryEvent(
            spec: .errorOccurred(
                domain: "Test",
                code: "42",
                description: "Failed /Users/alice/secret.wav via https://example.com/token?\(String(repeating: "x", count: 600))"
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
        let description = try XCTUnwrap(props["description"])

        XCTAssertEqual(props["domain"], "Test")
        XCTAssertEqual(props["code"], "42")
        XCTAssertFalse(description.contains("/Users/alice"))
        XCTAssertFalse(description.contains("example.com"))
        XCTAssertTrue(description.contains("<path>"))
        XCTAssertTrue(description.contains("<url>"))
        XCTAssertLessThanOrEqual(description.count, 512)
    }

    func testErrorDetailPropsAreSanitizedAtSerializationBoundary() throws {
        let rawDetail = "Failed /Users/alice/private-meeting.m4a via https://example.com/token?secret=abc"
        let specs: [TelemetryEventSpec] = [
            .dictationFailed(errorType: "runtime", errorDetail: rawDetail),
            .transcriptionFailed(source: .file, stage: .stt, errorType: "runtime", errorDetail: rawDetail),
            .diarizationFailed(source: .meeting, errorType: "runtime", errorDetail: rawDetail),
            .llmPromptResultFailed(provider: "openai", errorType: "provider", errorDetail: rawDetail),
            .llmChatFailed(provider: "openai", errorType: "provider", errorDetail: rawDetail),
            .llmTransformFailed(provider: "openai", errorType: "provider", errorDetail: rawDetail),
            .licenseActivationFailed(errorType: "network", errorDetail: rawDetail),
            .restoreFailed(errorType: "network", errorDetail: rawDetail),
            .modelDownloadFailed(errorType: "network", errorDetail: rawDetail),
            .meetingRecordingFailed(errorType: "runtime", errorDetail: rawDetail),
            .meetingRecoveryFailed(count: 1, source: .settings, errorType: "runtime", errorDetail: rawDetail),
        ]

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        for spec in specs {
            let event = TelemetryEvent(
                spec: spec,
                appVer: "0.4.2",
                osVer: "15.3",
                locale: "en-US",
                chip: "Apple M1",
                session: "test-session"
            )
            let data = try encoder.encode(event)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let props = try XCTUnwrap(json["props"] as? [String: String])
            let eventName = spec.name.rawValue
            let detail = try XCTUnwrap(props["error_detail"], "Missing error_detail for \(eventName)")

            XCTAssertFalse(detail.contains("/Users/alice"), eventName)
            XCTAssertFalse(detail.contains("private-meeting"), eventName)
            XCTAssertFalse(detail.contains("example.com"), eventName)
            XCTAssertTrue(detail.contains("<path>"), eventName)
            XCTAssertTrue(detail.contains("<url>"), eventName)
            XCTAssertLessThanOrEqual(detail.count, 512, eventName)
        }
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
                diarizationApplied: true
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

    func testMeetingRecoveryCompletedSerializesSafeProps() throws {
        let event = TelemetryEvent(
            spec: .meetingRecoveryCompleted(count: 2, durationSeconds: 4.25, source: .settings),
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

        XCTAssertEqual(json["event"] as? String, "meeting_recovery_completed")
        XCTAssertEqual(props["count"], "2")
        XCTAssertEqual(props["duration_seconds"], "4.2")
        XCTAssertEqual(props["source"], "settings")
        XCTAssertNil(props["session_id"])
        XCTAssertNil(props["file_path"])
    }

    func testCanonicalOperationSerializesSafeDimensionsOnly() throws {
        let event = TelemetryEvent(
            spec: .transcriptionOperation(
                operationID: "op-123",
                outcome: .success,
                source: .file,
                stage: .postProcessing,
                durationSeconds: 15.8,
                audioDurationSeconds: 90,
                processingSeconds: 12.4,
                wordCount: 240,
                speakerCount: 2,
                diarizationRequested: true,
                diarizationApplied: true,
                inputKind: .audio,
                mediaExtension: "m4a",
                fileSizeBucket: "10_100mb",
                errorType: nil
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

        XCTAssertEqual(json["event"] as? String, "transcription_operation")
        XCTAssertEqual(props["operation_id"], "op-123")
        XCTAssertEqual(props["outcome"], "success")
        XCTAssertEqual(props["source"], "file")
        XCTAssertEqual(props["duration_seconds"], "15.8")
        XCTAssertEqual(props["input_kind"], "audio")
        XCTAssertEqual(props["media_extension"], "m4a")
        XCTAssertEqual(props["file_size_bucket"], "10_100mb")
        XCTAssertNil(props["file_path"])
        XCTAssertNil(props["file_name"])
        XCTAssertNil(props["source_url"])
    }

    func testOperationContextSerializesWorkflowParentAndStage() throws {
        let context = ObservabilityOperationContext(
            operationID: "op-meeting",
            workflowID: "workflow-123",
            parentOperationID: "op-cli",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let event = TelemetryEvent(
            spec: .meetingOperation(
                operationID: context.operationID,
                operationContext: context,
                outcome: .failure,
                trigger: .calendarAutoStart,
                stage: .permissions,
                durationSeconds: nil,
                liveWordCount: nil,
                liveTranscriptLagged: nil,
                microphoneTrackPresent: nil,
                systemTrackPresent: nil,
                notesUsed: nil,
                notesLengthBucket: nil,
                errorType: "permission_denied"
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

        XCTAssertEqual(json["event"] as? String, "meeting_operation")
        XCTAssertEqual(props["operation_id"], "op-meeting")
        XCTAssertEqual(props["workflow_id"], "workflow-123")
        XCTAssertEqual(props["parent_operation_id"], "op-cli")
        XCTAssertEqual(props["stage"], "permissions")
        XCTAssertEqual(props["error_type"], "permission_denied")
    }

    func testDictationOperationDoesNotSerializeDeviceNameOrUID() throws {
        let device = RecordingDeviceInfo(
            deviceName: "Alice's Custom Microphone",
            transport: "bluetooth",
            subTransport: nil,
            sampleRate: 48_000,
            channels: 1,
            fallbackUsed: false,
            deviceUID: "secret-device-uid",
            requestedDeviceUID: "secret-requested-uid"
        )
        let event = TelemetryEvent(
            spec: .dictationOperation(
                operationID: "op-dict",
                outcome: .success,
                trigger: .hotkey,
                mode: .persistent,
                durationSeconds: 2.4,
                wordCount: 10,
                errorType: nil,
                device: device
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

        XCTAssertEqual(props["device_transport"], "bluetooth")
        XCTAssertEqual(props["device_selected"], "true")
        XCTAssertNil(props["device_name"])
        XCTAssertNil(props["device_uid"])
        XCTAssertNil(props["requested_device_uid"])
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
        let handled = await service.sendAndFlush(.appLaunched)
        XCTAssertTrue(handled)
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
            .dictationOperation(
                operationID: "op-dict",
                outcome: .success,
                trigger: .hotkey,
                mode: .persistent,
                durationSeconds: 12.5,
                wordCount: 84,
                errorType: nil
            ),
            .transcriptionStarted(source: .file, audioDurationSeconds: 30.0),
            .transcriptionCompleted(
                source: .dragDrop,
                audioDurationSeconds: 30.0,
                processingSeconds: 2.4,
                wordCount: 120,
                speakerCount: 2,
                diarizationRequested: true,
                diarizationApplied: true
            ),
            .transcriptionCancelled(source: .youtube, audioDurationSeconds: 45.0, stage: .stt),
            .transcriptionFailed(source: .file, stage: .audioConversion, errorType: "transcribe"),
            .transcriptionOperation(
                operationID: "op-transcription",
                outcome: .success,
                source: .dragDrop,
                stage: .postProcessing,
                durationSeconds: 2.9,
                audioDurationSeconds: 30.0,
                processingSeconds: 2.4,
                wordCount: 120,
                speakerCount: 2,
                diarizationRequested: true,
                diarizationApplied: true,
                inputKind: .audio,
                mediaExtension: "mp3",
                fileSizeBucket: "1_10mb",
                errorType: nil
            ),
            .exportUsed(format: "txt"),
            .llmPromptResultUsed(provider: "openai"),
            .llmPromptResultFailed(provider: "openai", errorType: "auth"),
            .llmChatUsed(provider: "openai", messageCount: 3),
            .llmChatFailed(provider: "openai", errorType: "network"),
            .llmTransformUsed(provider: "openai"),
            .llmTransformFailed(provider: "openai", errorType: "network"),
            .llmFormatterUsed(
                provider: "lmstudio",
                source: .dictation,
                durationSeconds: 1.2,
                inputChars: 480,
                outputChars: 512,
                defaultPromptUsed: true,
                inputTruncated: false
            ),
            .llmFormatterFailed(
                provider: "lmstudio",
                source: .transcription,
                durationSeconds: 0.4,
                errorType: "network",
                defaultPromptUsed: false,
                inputTruncated: true
            ),
            .llmOperation(
                operationID: "op-llm",
                feature: "chat",
                provider: "openai",
                streaming: false,
                outcome: .success,
                durationSeconds: 1.2,
                inputChars: 480,
                outputChars: 512,
                inputTruncated: false,
                promptDefaultUsed: nil,
                messageCount: 3,
                errorType: nil
            ),
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
            .feedbackOperation(
                operationID: "op-feedback",
                category: "bug",
                outcome: .success,
                durationSeconds: 0.6,
                screenshotAttached: false,
                systemInfoIncluded: true,
                errorType: nil
            ),
            .onboardingStep(step: "microphone"),
            .licenseActivationFailed(errorType: "invalid_key"),
            .keystrokeSnippetFired(action: "return"),
            .meetingRecordingStarted(),
            .meetingRecordingCompleted(durationSeconds: 1800.0, liveWordCount: 4200, liveTranscriptLagged: false),
            .meetingRecordingCancelled(durationSeconds: 30.0),
            .meetingRecordingFailed(errorType: "tap_creation_failed"),
            .meetingOperation(
                operationID: "op-meeting",
                outcome: .success,
                trigger: .manual,
                durationSeconds: 1800.0,
                liveWordCount: 4200,
                liveTranscriptLagged: false,
                microphoneTrackPresent: true,
                systemTrackPresent: true,
                notesUsed: true,
                notesLengthBucket: "1_200",
                errorType: nil
            ),
            .meetingRecoveryDiscovered(count: 1, source: .launch),
            .meetingRecoveryStarted(count: 1, source: .launch),
            .meetingRecoveryCompleted(count: 1, durationSeconds: 4.2, source: .launch),
            .meetingRecoveryDiscarded(count: 1, source: .settings),
            .meetingRecoveryFailed(count: 1, source: .settings, errorType: "no_audio"),
            .errorOccurred(domain: "STTError", code: "engineFailed", description: "test"),
            .crashOccurred(
                crashType: "signal", signal: "11", name: "SIGSEGV",
                crashTimestamp: "1711900000", crashAppVer: "0.5.1",
                crashOsVer: "15.3.1", uuid: "A1B2C3D4", slide: "0x100000",
                reason: nil, stackTrace: "0x1234\n0x5678"
            ),
            .cliOperation(
                operationID: "op-cli",
                command: "transcribe",
                subcommand: nil,
                outcome: .success,
                durationSeconds: 4.2,
                inputKind: .audio,
                outputFormat: "json",
                json: true,
                exitCode: 0,
                errorType: nil
            ),
            .autoSaveOperation(
                operationID: "op-auto-save",
                scope: .transcription,
                format: .md,
                outcome: .success,
                durationSeconds: 0.2,
                errorType: nil
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
