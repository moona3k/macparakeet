import Darwin
import Foundation
import os
import XCTest
@testable import MacParakeetCore

final class CrashReportStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: CrashReportStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = CrashReportStore(appSupportURL: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func report(_ version: String = "0.8.9") -> String {
        "crash_type: signal\nsignal: 6\nname: SIGABRT\ntimestamp: 123\napp_ver: \(version)\n"
    }

    @discardableResult
    private func pendingReport(_ content: String? = nil) throws -> URL {
        let lease = try XCTUnwrap(store.reserve())
        try (content ?? report()).write(to: lease.reportURL, atomically: true, encoding: .utf8)
        return lease.reportURL
    }

    func testLiveReservationsHaveDistinctPathsAndCannotBeClaimedOrPruned() throws {
        let first = try XCTUnwrap(store.reserve())
        let second = try XCTUnwrap(store.reserve())
        XCTAssertNotEqual(first.reportURL, second.reportURL)
        try report().write(to: first.reportURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.claimPendingReports().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.reportURL.path))
        withExtendedLifetime((first, second)) {}
    }

    func testAllLiveCapacityDeclinesReservationWithoutTouchingReports() throws {
        var leases: [CrashReportStore.Lease] = []
        for _ in 0..<CrashReportStore.capacity {
            let lease = try XCTUnwrap(store.reserve())
            try report().write(to: lease.reportURL, atomically: true, encoding: .utf8)
            leases.append(lease)
        }
        XCTAssertNil(store.reserve())
        XCTAssertTrue(store.claimPendingReports().isEmpty)
        XCTAssertTrue(leases.allSatisfy { FileManager.default.fileExists(atPath: $0.reportURL.path) })
        withExtendedLifetime(leases) {}
    }

    func testCapacityEvictsOldestUnlockedReportAndPreservesLiveLease() throws {
        let live = try XCTUnwrap(store.reserve())
        try report().write(to: live.reportURL, atomically: true, encoding: .utf8)
        var paths: [URL] = []
        for index in 0..<(CrashReportStore.capacity - 1) {
            let url = try pendingReport()
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(100 + index))],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
            paths.append(url)
        }
        let newest = try XCTUnwrap(store.reserve())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0].path))
        XCTAssertTrue(paths.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.reportURL.path))
        withExtendedLifetime((live, newest)) {}
    }

    func testClaimExcludesOtherDrainerAndRetentionUntilReleased() throws {
        let url = try pendingReport()
        let claims = store.claimPendingReports()
        XCTAssertEqual(claims.map(\.reportURL), [url])
        XCTAssertTrue(store.claimPendingReports().isEmpty)
        var live: [CrashReportStore.Lease] = []
        for _ in 1..<CrashReportStore.capacity { live.append(try XCTUnwrap(store.reserve())) }
        XCTAssertNil(store.reserve())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        withExtendedLifetime((claims, live)) {}
    }

    func testDeadEmptyReservationsAreRemovedByDrain() throws {
        var reservation: CrashReportStore.Lease? = try XCTUnwrap(store.reserve())
        let directory = try XCTUnwrap(reservation?.reportURL.deletingLastPathComponent())
        reservation = nil
        XCTAssertTrue(store.claimPendingReports().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testQueueLockContentionReturnsWithoutWaiting() throws {
        var initial: CrashReportStore.Lease? = try XCTUnwrap(store.reserve())
        initial = nil
        let descriptor = open(store.rootURL.appendingPathComponent(".queue.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertNil(store.reserve())
        XCTAssertTrue(store.claimPendingReports().isEmpty)
        withExtendedLifetime(initial) {}
    }

    func testTraversalBudgetDeclinesReservationAndPreservesUnrelatedEntries() throws {
        try FileManager.default.createDirectory(at: store.rootURL, withIntermediateDirectories: false)
        for index in 0..<CrashReportStore.scanLimit {
            try Data().write(to: store.rootURL.appendingPathComponent("unrelated-\(index)"))
        }
        XCTAssertNil(store.reserve())  // .queue.lock is the 65th entry.
        XCTAssertTrue(store.claimPendingReports().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent("unrelated-0").path))
    }

    func testSymlinkSpoolAndUnexpectedParentFileAreNotReplaced() throws {
        let target = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: store.rootURL, withDestinationURL: target)
        XCTAssertNil(store.reserve())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let parentFile = temporaryDirectory.appendingPathComponent("parent-file")
        try Data("keep".utf8).write(to: parentFile)
        XCTAssertNil(CrashReportStore(appSupportURL: parentFile).reserve())
        XCTAssertEqual(try String(contentsOf: parentFile), "keep")
    }

    func testReportSymlinkIsNeitherReadNorDeleted() throws {
        let target = temporaryDirectory.appendingPathComponent("outside.txt")
        try report().write(to: target, atomically: true, encoding: .utf8)
        var lease: CrashReportStore.Lease? = try XCTUnwrap(store.reserve())
        let url = try XCTUnwrap(lease?.reportURL)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        lease = nil
        XCTAssertNil(CrashReporter.loadPendingReport(from: url.path))
        let claims = store.claimPendingReports()
        XCTAssertEqual(claims.count, 1)
        XCTAssertFalse(store.discard(try XCTUnwrap(claims.first)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
    }

    /// The handled report is ours to remove, but an unexpected sibling keeps
    /// the directory: it is never recursively deleted.
    func testUnexpectedFileInsideManagedDirectoryIsPreserved() throws {
        let url = try pendingReport()
        let extra = url.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: extra)
        let claim = try XCTUnwrap(store.claimPendingReports().first)
        XCTAssertFalse(store.discard(claim))
        XCTAssertEqual(try String(contentsOf: extra), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOversizedAndMalformedOwnedReportsAreBoundedAndRetained() async throws {
        let large = try pendingReport(report() + String(repeating: "a", count: CrashReportStore.maximumReportBytes))
        let malformed = try pendingReport("incomplete crash")
        XCTAssertNil(CrashReporter.loadPendingReport(from: large.path))
        let telemetry = StoreTelemetry()
        await CrashReporter.sendPendingReports(via: telemetry, store: store)
        XCTAssertEqual(telemetry.events.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: large.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
    }

    func testFailedFlushRetainsReportAndSuccessfulFlushDiscardsIt() async throws {
        let url = try pendingReport()
        let failure = StoreTelemetry(result: false)
        await CrashReporter.sendPendingReports(via: failure, store: store)
        XCTAssertEqual(failure.events.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let success = StoreTelemetry()
        await CrashReporter.sendPendingReports(via: success, store: store)
        XCTAssertEqual(success.events.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testIntentionalOptOutDiscardRemovesReportWithoutNetwork() async throws {
        let url = try pendingReport()
        await CrashReporter.sendPendingReports(via: NoOpTelemetryService(), store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLegacyIsAdoptedBeforeAwaitAndReplacementSurvives() async throws {
        try report("legacy").write(to: store.legacyURL, atomically: true, encoding: .utf8)
        let legacyURL = store.legacyURL
        let replacement = report("replacement")
        let telemetry = StoreTelemetry { _ in
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
            try? replacement.write(to: legacyURL, atomically: true, encoding: .utf8)
            return true
        }
        await CrashReporter.sendPendingReports(via: telemetry, store: store)
        XCTAssertEqual(telemetry.events.count, 1)
        XCTAssertEqual(try String(contentsOf: legacyURL), replacement)
        guard
            case .crashOccurred(_, _, _, _, let version, _, _, _, _, _, _, _, _, let metadata) = telemetry.events.first
        else {
            return XCTFail("Expected legacy crash")
        }
        XCTAssertEqual(version, "legacy")
        XCTAssertNil(metadata?.props["crash_id"])
    }

    func testNewReportDuringUploadRemainsPending() async throws {
        let original = try pendingReport("crash_type: signal\nsignal: 6\nname: SIGABRT\ntimestamp: 1\napp_ver: first\n")
        let currentStore = try XCTUnwrap(store)
        let createdPath = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let content = report("second")
        let telemetry = StoreTelemetry { _ in
            guard let lease = currentStore.reserve() else { XCTFail("Expected free slot"); return false }
            try? content.write(to: lease.reportURL, atomically: true, encoding: .utf8)
            createdPath.withLock { $0 = lease.reportURL }
            return true
        }
        await CrashReporter.sendPendingReports(via: telemetry, store: store)
        XCTAssertEqual(telemetry.events.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let newURL = try XCTUnwrap(createdPath.withLock { $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        let second = StoreTelemetry()
        await CrashReporter.sendPendingReports(via: second, store: store)
        XCTAssertEqual(second.events.count, 1)
    }

    func testUnreadableReportIsRetainedAndRetriedAfterPermissionsRecover() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses file read permissions") }
        let url = try pendingReport()
        XCTAssertEqual(chmod(url.path, 0), 0)
        defer { _ = chmod(url.path, S_IRUSR | S_IWUSR) }
        let telemetry = StoreTelemetry()
        await CrashReporter.sendPendingReports(via: telemetry, store: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(telemetry.events.isEmpty)
        XCTAssertEqual(chmod(url.path, S_IRUSR | S_IWUSR), 0)
        await CrashReporter.sendPendingReports(via: telemetry, store: store)
        XCTAssertEqual(telemetry.events.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func reportWithContext(_ packed: UInt64) -> String {
        report() + """
            crash_context_version: 1
            crash_id: a17e1881-3d55-4ab8-af5f-32dedd0571c4
            crash_session: 57b2573a-8629-4d7e-8c24-42304d44d388
            breadcrumb: 1,0x\(String(packed, radix: 16))

            """
    }

    func testArchivePrecedesUploadAndKeepsBreadcrumbsLocal() async throws {
        let packed = CrashAudioContext.Record(kind: .phase, phase: .startEngine, attempt: 7).packed
        let url = try pendingReport(reportWithContext(packed))
        let log = temporaryDirectory.appendingPathComponent("archive.log")
        let telemetry = StoreTelemetry { _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "Archive must precede upload")
            return true
        }
        await CrashReporter.sendPendingReports(via: telemetry, store: store) { try $0.persist(to: log) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let archived = try String(contentsOf: log)
        XCTAssertTrue(archived.contains("crash_records=1:0x\(String(packed, radix: 16))"))
        XCTAssertEqual(telemetry.events.first?.props?["crash_id"], "a17e1881-3d55-4ab8-af5f-32dedd0571c4")
        XCTAssertNil(telemetry.events.first?.props?["crash_records"])
    }

    /// Telemetry reports an opt-out drop as handled. A failed local archive must
    /// not keep that report pending, or a later opt-in would upload it.
    func testFailedArchiveStillDiscardsHandledReportSoLaterOptInCannotUploadIt() async throws {
        let packed = CrashAudioContext.Record(kind: .phase, phase: .startEngine, attempt: 7).packed
        let url = try pendingReport(reportWithContext(packed))
        let optedOut = StoreTelemetry(result: true)
        await CrashReporter.sendPendingReports(via: optedOut, store: store) { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EWOULDBLOCK))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let optedIn = StoreTelemetry()
        await CrashReporter.sendPendingReports(via: optedIn, store: store)
        XCTAssertTrue(optedIn.events.isEmpty)
    }

    /// Another process can hold the spool queue lock while an opt-out drop
    /// completes. The handled report must still be gone for a later opt-in.
    func testQueueLockContentionStillDiscardsHandledReport() async throws {
        let url = try pendingReport()
        let queueLock = store.rootURL.appendingPathComponent(".queue.lock").path
        let contender = open(queueLock, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(contender, 0)
        defer { close(contender) }
        let optedOut = StoreTelemetry { _ in
            // Claims are taken before delivery; contend only for the discard.
            flock(contender, LOCK_EX | LOCK_NB) == 0
        }
        await CrashReporter.sendPendingReports(via: optedOut, store: store)
        XCTAssertEqual(optedOut.events.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        XCTAssertEqual(flock(contender, LOCK_UN), 0)
        let optedIn = StoreTelemetry()
        await CrashReporter.sendPendingReports(via: optedIn, store: store)
        XCTAssertTrue(optedIn.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testConcurrentDrainsDoNotSendTheSameReportTwice() async throws {
        _ = try pendingReport()
        let gate = StoreDeliveryGate()
        let telemetry = StoreTelemetry { _ in
            await gate.pause()
            return true
        }
        let currentStore = try XCTUnwrap(store)
        let first = Task { await CrashReporter.sendPendingReports(via: telemetry, store: currentStore) }
        await gate.waitUntilPaused()
        await CrashReporter.sendPendingReports(via: telemetry, store: currentStore)
        XCTAssertEqual(telemetry.events.count, 1)
        await gate.resume()
        await first.value
    }
}

private final class StoreTelemetry: TelemetryServiceProtocol, @unchecked Sendable {
    private let recorded = OSAllocatedUnfairLock<[TelemetryEventSpec]>(initialState: [])
    private let delivery: @Sendable (TelemetryEventSpec) async -> Bool
    var events: [TelemetryEventSpec] { recorded.withLock { $0 } }

    init(result: Bool = true) { delivery = { _ in result } }
    init(delivery: @escaping @Sendable (TelemetryEventSpec) async -> Bool) { self.delivery = delivery }
    func send(_ event: TelemetryEventSpec) { recorded.withLock { $0.append(event) } }
    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return await delivery(event)
    }
    func clearQueue() { recorded.withLock { $0.removeAll() } }
    func flush() async {}
    func flushForTermination() {}
}

private actor StoreDeliveryGate {
    private var paused = false
    private var observer: CheckedContinuation<Void, Never>?
    private var delivery: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { delivery = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { delivery?.resume(); delivery = nil }
}
