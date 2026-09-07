import XCTest
import FluidAudio
@testable import MacParakeetCore

/// FluidAudio 0.15.6 runs an encoder prediction while loading the Nemotron
/// English models (`encoderProducesNonZeroOutput`), so model preparation is
/// Neural Engine inference and must wait for the macOS 14 gate like every
/// transcription call. Ordering is established with explicit signals, not
/// sleeps: the holder signals `acquired` once it owns the permit and keeps
/// it until the test signals `release`.
final class NemotronEnglishEngineLoadGatingTests: XCTestCase {

    private actor Probe {
        var holderActive = false
        var loaderObservations: [Bool] = []
        var downloadObservations: [Bool] = []

        func setHolderActive(_ value: Bool) { holderActive = value }
        func recordLoad() { loaderObservations.append(holderActive) }
        func recordDownload() { downloadObservations.append(holderActive) }
    }

    private func makeEngine(gate: ANEInferenceGate, probe: Probe) -> NemotronEnglishEngine {
        NemotronEnglishEngine(
            inferenceGate: gate,
            managerLoader: { _, _, _ in await probe.recordLoad() },
            modelDownloader: { _, _ in await probe.recordDownload() }
        )
    }

    private func holdGate(_ gate: ANEInferenceGate, probe: Probe, acquired: AsyncPermit, release: AsyncPermit) -> Task<Void, Error> {
        Task {
            try await gate.withExclusiveAccess {
                await probe.setHolderActive(true)
                acquired.signal()
                try await release.wait()
                await probe.setHolderActive(false)
            }
        }
    }

    func testPrepareWaitsForAnInFlightInferenceOnASerializingGate() async throws {
        let gate = ANEInferenceGate(serializationRequired: true)
        let probe = Probe()
        let acquired = AsyncPermit(value: 0)
        let release = AsyncPermit(value: 0)
        let holder = holdGate(gate, probe: probe, acquired: acquired, release: release)
        try await acquired.wait()

        let engine = makeEngine(gate: gate, probe: probe)
        let preparation = Task { try await engine.prepare() }
        // The download step is ungated and must run while the holder still owns the permit.
        while await probe.downloadObservations.isEmpty {
            await Task.yield()
        }
        let downloadsWhileHeld = await probe.downloadObservations
        XCTAssertEqual(downloadsWhileHeld, [true], "the download runs before the gate is taken")
        let loadsWhileHeld = await probe.loaderObservations
        XCTAssertTrue(loadsWhileHeld.isEmpty, "no manager load may run while another inference holds the permit")

        release.signal()
        try await holder.value
        try await preparation.value

        let observations = await probe.loaderObservations
        XCTAssertEqual(observations, [false, false], "both lane managers loaded only after the holder released the gate")
        let ready = await engine.isReady()
        XCTAssertTrue(ready)
    }

    func testPrepareDoesNotWaitWhenSerializationIsNotRequired() async throws {
        let gate = ANEInferenceGate(serializationRequired: false)
        let probe = Probe()
        let acquired = AsyncPermit(value: 0)
        let release = AsyncPermit(value: 0)
        let holder = holdGate(gate, probe: probe, acquired: acquired, release: release)
        try await acquired.wait()

        let engine = makeEngine(gate: gate, probe: probe)
        // Completes while the holder still owns the (no-op) gate.
        try await engine.prepare()
        let observations = await probe.loaderObservations
        XCTAssertEqual(observations, [true, true], "macOS 15+ keeps loads concurrent with inference")

        release.signal()
        try await holder.value
    }

    func testLoaderFailurePropagatesAndLeavesEngineNotReady() async {
        let engine = NemotronEnglishEngine(
            inferenceGate: ANEInferenceGate(serializationRequired: true),
            managerLoader: { _, _, _ in throw ASRError.modelLoadFailed },
            modelDownloader: { _, _ in }
        )

        do {
            try await engine.prepare()
            XCTFail("expected the loader error")
        } catch {
            // Mapped by the engine's error mapper.
        }
        let ready = await engine.isReady()
        XCTAssertFalse(ready)
    }
}
