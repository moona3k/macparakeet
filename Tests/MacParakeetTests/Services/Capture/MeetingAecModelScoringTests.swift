import XCTest
@testable import MacParakeetCore

/// Env-gated LocalVQE **model decision gate** for meeting AEC (issue #605, plan
/// unit U5). Scores candidate echo-cancellation GGUF models on the synthetic
/// measurement harness so the release default can be chosen by the plan's rule:
/// best near-end retention at acceptable far-end ERLE, ties broken toward the
/// echo-only `v1.4-aec` model.
///
/// The test is **skipped** unless the private LocalVQE assets are pointed at via
/// environment, so the full suite stays green in CI without them. Run locally:
///
///   MACPARAKEET_TEST_LOCALVQE_LIBRARY=/path/to/liblocalvqe.dylib \
///   MACPARAKEET_TEST_LOCALVQE_MODELS=/path/a.gguf:/path/b.gguf \
///   swift test --filter MeetingAecModelScoringTests
///
/// `MACPARAKEET_TEST_LOCALVQE_MODELS` is a `:`- or newline-separated list of
/// absolute `.gguf` paths; missing files are reported and skipped.
///
/// **What the harness can and cannot prove.** The near-end is decorrelated,
/// voiced-like *tones*, not speech. So the gate asserts only on the axes the
/// fixture measures reliably — far-end echo removal (ERLE) and near-end *energy*
/// retention — and merely *reports* the waveform-fidelity numbers (near-end
/// error, double-talk improvement), because a neural model trained on real speech
/// reshapes synthetic tones in ways that penalize exact-waveform error whether or
/// not it would damage real speech. Real speaker-mode QA (plan unit U9) owns
/// fidelity and remains the binding gate before any default-on.
final class MeetingAecModelScoringTests: XCTestCase {
    private static let libraryKey = "MACPARAKEET_TEST_LOCALVQE_LIBRARY"
    private static let modelsKey = "MACPARAKEET_TEST_LOCALVQE_MODELS"

    // Robust-axis gates (calibrated with margin to the chosen v1.4 candidate:
    // ERLE 35.6 dB, retain 1.02). A shippable model must remove strong echo and
    // preserve the local voice's energy without amplifying it.
    private static let minFarEndERLE = 15.0
    private static let minRetention: Float = 0.8
    private static let maxRetention: Float = 1.5

    // Single dominant tap and a short multi-tap room response — the same echo
    // paths the measurement tests use, so the scoring is on familiar fixtures.
    private let singleTapEcho = MeetingAecEchoPath(taps: [(delay: 120, gain: 0.6)])
    private let multiTapEcho = MeetingAecEchoPath(
        taps: [(delay: 120, gain: 0.6), (delay: 180, gain: 0.25), (delay: 240, gain: 0.12)]
    )

    private struct ModelScore {
        let label: String      // display name (filename)
        let modelKey: String   // full path — dedup key so same-named models don't merge
        let echoLabel: String
        /// Far-end-only steady-state ERLE (dB). Higher = more echo removed.
        let farEndERLE: Double
        /// Near-end-only error vs the ideal local voice (dB). Reported, not gated:
        /// a neural model reshapes synthetic tones, so this is unreliable here.
        let nearEndErrorDB: Double
        /// Output-vs-mic RMS ratio on near-end-only. ~1.0 = local voice energy
        /// preserved; near 0 = the model went silent / gutted the local voice.
        let nearEndRetentionRatio: Float
        /// Double-talk near-end error (dB) and the passthrough baseline on the
        /// same fixture. Reported, not gated (see fidelity caveat).
        let doubleTalkErrorDB: Double
        let doubleTalkPassthroughErrorDB: Double
        let processedFrames: Int
        /// Frames the processor failed (threw / wrong-sized output) and the
        /// suppressor served raw instead. Nonzero means the scores are polluted by
        /// raw-fallback frames, so the gate rejects it.
        let processingFailures: Int
        let delaySamples: Int

        /// Positive = the model reduced near-end error under double-talk vs raw.
        var doubleTalkImprovement: Double { doubleTalkPassthroughErrorDB - doubleTalkErrorDB }
    }

    private struct ModelAggregate {
        let label: String
        let meanFarERLE: Double
        let meanDoubleTalkError: Double
        let meanDoubleTalkImprovement: Double
        let minRetention: Float
        let maxRetention: Float
        let meanNearError: Double
        let totalProcessingFailures: Int
    }

    func testLocalVQEModelDecisionGate() throws {
        let env = ProcessInfo.processInfo.environment
        guard let libraryPath = env[Self.libraryKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !libraryPath.isEmpty else {
            throw XCTSkip("Set \(Self.libraryKey) and \(Self.modelsKey) to score real LocalVQE models.")
        }
        guard let modelsRaw = env[Self.modelsKey], !modelsRaw.isEmpty else {
            throw XCTSkip("Set \(Self.modelsKey) to a :-separated list of .gguf paths.")
        }

        let libraryURL = URL(fileURLWithPath: libraryPath)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: libraryURL.path),
            "LocalVQE library not found: \(libraryURL.path)")

        let modelURLs = modelsRaw
            .split(whereSeparator: { $0 == ":" || $0 == "\n" })
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { url in
                let exists = FileManager.default.fileExists(atPath: url.path)
                if !exists { print("[AEC-SCORE] skipping missing model: \(url.path)") }
                return exists
            }
        try XCTSkipIf(modelURLs.isEmpty, "No existing model files in \(Self.modelsKey).")

        let echoPaths: [(String, MeetingAecEchoPath)] = [
            ("single-tap", singleTapEcho),
            ("multi-tap", multiTapEcho),
        ]

        var scores: [ModelScore] = []
        for modelURL in modelURLs {
            // Preflight: the factory falls back to an unavailable passthrough
            // (loaded == false) when the dylib/model can't instantiate. Fail with
            // one crisp message rather than scoring a bogus passthrough as the model.
            let preflight = makeConditioner(libraryURL: libraryURL, modelURL: modelURL)
            guard preflight.diagnostics.loaded,
                  preflight.diagnostics.processorName == MeetingEchoSuppressionFactory.processorName else {
                XCTFail("\(modelURL.lastPathComponent): not a loadable LocalVQE model — the runtime "
                    + "fell back to passthrough. Exclude it from \(Self.modelsKey) or rebuild the asset.")
                continue
            }
            for (echoLabel, echoPath) in echoPaths {
                scores.append(scoreModel(
                    label: modelURL.lastPathComponent,
                    modelKey: modelURL.path,
                    echoLabel: echoLabel,
                    libraryURL: libraryURL,
                    modelURL: modelURL,
                    echoPath: echoPath))
            }
        }
        try XCTSkipIf(scores.isEmpty, "No candidate models loaded successfully.")

        printScoreTable(scores)
        let aggregates = aggregate(scores)
        printAggregates(aggregates)

        // No silent contamination: a loaded processor that throws on frames falls
        // back to raw mic, which inflates retention and pollutes ERLE/near-end. And
        // every model must actually process frames, not sit at passthrough.
        for s in scores {
            XCTAssertEqual(s.processingFailures, 0,
                "\(s.label)/\(s.echoLabel): \(s.processingFailures) processing failures — "
                + "scores include raw-fallback frames and cannot be trusted")
            XCTAssertGreaterThan(s.processedFrames, 0,
                "\(s.label)/\(s.echoLabel): no frames processed — asset failed to load")
        }

        // Teeth on the ROBUST axes only (see the type doc). A shippable model must
        // remove strong far-end echo AND keep the local voice's energy without
        // amplifying it; fidelity under double-talk is U9's call, not asserted here.
        let viable = aggregates.filter {
            $0.meanFarERLE > Self.minFarEndERLE
                && $0.minRetention > Self.minRetention
                && $0.maxRetention < Self.maxRetention
        }
        guard let chosen = viable.min(by: { $0.meanDoubleTalkError < $1.meanDoubleTalkError }) else {
            XCTFail("No candidate both removed far-end echo (>\(Self.minFarEndERLE) dB ERLE) and "
                + "preserved the near-end voice (retain "
                + "\(Self.minRetention)–\(Self.maxRetention)). Re-plan / consider WebRTC AEC3 (plan U6).")
            return
        }
        print("[AEC-SCORE] recommended release default: \(chosen.label) — removes echo, preserves the "
            + "local voice. Double-talk fidelity pending real-speech QA (plan U9).")
    }

    // MARK: Scoring

    private func scoreModel(
        label: String,
        modelKey: String,
        echoLabel: String,
        libraryURL: URL,
        modelURL: URL,
        echoPath: MeetingAecEchoPath
    ) -> ModelScore {
        // Far-end-only → ERLE (any mic energy is echo by construction).
        let farScenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true, echoPath: echoPath)
        let farOut = MeetingAecRunner.run(
            makeConditioner(libraryURL: libraryURL, modelURL: modelURL), scenario: farScenario)
        let farERLE = MeetingAecMetrics.erleDB(
            mic: farScenario.mic, output: farOut, over: farScenario.steadyStateWindow)

        // Near-end-only → must preserve the local voice's energy and not go silent.
        let nearScenario = MeetingAecScenarioFactory.make(
            name: "near-end-only", nearEndActive: true, farEndActive: false, echoPath: echoPath)
        let nearOut = MeetingAecRunner.run(
            makeConditioner(libraryURL: libraryURL, modelURL: modelURL), scenario: nearScenario)
        let nearWindow = nearScenario.steadyStateWindow
        let nearErr = MeetingAecMetrics.nearEndErrorDB(
            output: nearOut, nearEnd: nearScenario.nearEnd, over: nearWindow)
        let retention = rmsRatio(nearOut, scenario: nearScenario, over: nearWindow)

        // Double-talk → near-end error vs passthrough (reported, not gated).
        let dtScenario = MeetingAecScenarioFactory.make(
            name: "double-talk", nearEndActive: true, farEndActive: true, echoPath: echoPath)
        let dtConditioner = makeConditioner(libraryURL: libraryURL, modelURL: modelURL)
        let dtOut = MeetingAecRunner.run(dtConditioner, scenario: dtScenario)
        let dtWindow = dtScenario.steadyStateWindow
        let dtErr = MeetingAecMetrics.nearEndErrorDB(
            output: dtOut, nearEnd: dtScenario.nearEnd, over: dtWindow)
        let dtPass = MeetingAecRunner.run(PassthroughMicConditioner(), scenario: dtScenario)
        let dtPassErr = MeetingAecMetrics.nearEndErrorDB(
            output: dtPass, nearEnd: dtScenario.nearEnd, over: dtWindow)
        // Diagnostics from the double-talk run, where both signals are present so
        // the adaptive delay estimator has reference energy to lock onto, and the
        // processor exercises the full mic+reference path.
        let diag = dtConditioner.diagnostics

        return ModelScore(
            label: label, modelKey: modelKey, echoLabel: echoLabel,
            farEndERLE: farERLE,
            nearEndErrorDB: nearErr,
            nearEndRetentionRatio: retention,
            doubleTalkErrorDB: dtErr, doubleTalkPassthroughErrorDB: dtPassErr,
            processedFrames: diag.processedFrames, processingFailures: diag.processingFailures,
            delaySamples: diag.currentDelaySamples)
    }

    private func makeConditioner(libraryURL: URL, modelURL: URL) -> any MicConditioning {
        MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: libraryURL,
                modelURL: modelURL),
            bundle: Bundle(for: Self.self))
    }

    private func rmsRatio(
        _ output: [Float], scenario: MeetingAecScenario, over window: Range<Int>
    ) -> Float {
        let outPower = MeetingAecMetrics.power(output, over: window)
        let micPower = MeetingAecMetrics.power(scenario.mic, over: window)
        guard micPower > 0 else { return 0 }
        return Float((outPower / micPower).squareRoot())
    }

    // MARK: Aggregation + reporting

    private func aggregate(_ scores: [ModelScore]) -> [ModelAggregate] {
        // Group by full path, not filename, so a rebuilt model with the same
        // basename in another directory doesn't silently merge with the original.
        let byModel = Dictionary(grouping: scores, by: { $0.modelKey })
        return byModel.values.map { group -> ModelAggregate in
            let n = Double(group.count)
            let retentions = group.map { $0.nearEndRetentionRatio }
            return ModelAggregate(
                label: group.first?.label ?? "?",
                meanFarERLE: group.reduce(0) { $0 + $1.farEndERLE } / n,
                meanDoubleTalkError: group.reduce(0) { $0 + $1.doubleTalkErrorDB } / n,
                meanDoubleTalkImprovement: group.reduce(0) { $0 + $1.doubleTalkImprovement } / n,
                minRetention: retentions.min() ?? 0,
                maxRetention: retentions.max() ?? 0,
                meanNearError: group.reduce(0) { $0 + $1.nearEndErrorDB } / n,
                totalProcessingFailures: group.reduce(0) { $0 + $1.processingFailures })
        }
    }

    private func printScoreTable(_ scores: [ModelScore]) {
        print("[AEC-SCORE] LocalVQE model decision gate — synthetic harness")
        print("[AEC-SCORE] GATED: ERLE higher better, retain in 0.8–1.5 | REPORTED only:"
            + " nearErr/dtErr/dtImpr (synthetic tones can't certify fidelity)")
        print(String(
            format: "  %-34@ %-11@ %9@ %10@ %10@ %10@ %9@ %7@ %6@ %5@",
            "model" as CVarArg, "echo" as CVarArg, "ERLE" as CVarArg,
            "nearErr" as CVarArg, "dtErr" as CVarArg, "dtRaw" as CVarArg,
            "dtImpr" as CVarArg, "retain" as CVarArg, "delay" as CVarArg, "fail" as CVarArg))
        for s in scores {
            print(String(
                format: "  %-34@ %-11@ %8.1f %9.1f %9.1f %9.1f %8.1f %6.2f %5ld %4ld",
                s.label as CVarArg, s.echoLabel as CVarArg,
                s.farEndERLE, s.nearEndErrorDB, s.doubleTalkErrorDB,
                s.doubleTalkPassthroughErrorDB, s.doubleTalkImprovement,
                Double(s.nearEndRetentionRatio), s.delaySamples, s.processingFailures))
        }
        print("[AEC-SCORE] (dtImpr = passthrough dtErr − model dtErr; positive = model helped"
            + " under double-talk. fail = frames that fell back to raw mic.)")
    }

    private func printAggregates(_ aggregates: [ModelAggregate]) {
        print("[AEC-SCORE] per-model aggregate (mean across echo paths):")
        for a in aggregates.sorted(by: { $0.meanFarERLE > $1.meanFarERLE }) {
            print(String(
                format: "  %-34@ farERLE %5.1f  dtErr %5.1f  dtImpr %5.1f  nearErr %5.1f  retain %.2f–%.2f  fails %ld",
                a.label as CVarArg, a.meanFarERLE, a.meanDoubleTalkError,
                a.meanDoubleTalkImprovement, a.meanNearError,
                Double(a.minRetention), Double(a.maxRetention), a.totalProcessingFailures))
        }
    }
}
