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
/// retention — and reports overlap-segment accuracy using the harness's existing
/// near-end error metric at 0/+6/+12 dB SIR. This is the synthetic equivalent of
/// double-talk WER: it is computed only where local speech overlaps reference
/// playback. It is still not a substitute for real-speech WER, because a neural
/// model trained on real speech reshapes synthetic tones in ways that penalize
/// exact-waveform error whether or not it would damage real speech. Real
/// speaker-mode QA (plan unit U9) owns fidelity and remains the binding gate
/// before any default-on.
final class MeetingAecModelScoringTests: XCTestCase {
    private static let libraryKey = "MACPARAKEET_TEST_LOCALVQE_LIBRARY"
    private static let modelsKey = "MACPARAKEET_TEST_LOCALVQE_MODELS"
    private static let doubleTalkSignalToInterferenceDBs = [0.0, 6.0, 12.0]

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

    private struct DoubleTalkSegmentScore {
        let signalToInterferenceDB: Double
        /// Overlap-segment near-end error. Lower is better; this is the harness's
        /// synthetic accuracy proxy for WER on local speech during double-talk.
        let cleanErrorDB: Double
        let rawErrorDB: Double
        /// Double-talk RMS ratio vs the expected local voice. Low values can
        /// expose over-suppression of the user; high values usually mean residual
        /// echo remains in the cleaned mic.
        let cleanRetentionRatio: Float
        let rawRetentionRatio: Float
        /// Echo-only output power relative to the nominal local voice. Lower is
        /// better, and should move toward silence / empty transcript.
        let echoOnlyCleanResidualDB: Double
        let echoOnlyRawResidualDB: Double
        let echoOnlyERLE: Double

        var improvementDB: Double { rawErrorDB - cleanErrorDB }
    }

    private struct OverlapSweepResult {
        let scores: [DoubleTalkSegmentScore]
        let diagnostics: [MeetingEchoSuppressionDiagnostics]
    }

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
        /// SIR-controlled overlap rows: the new double-talk segment metric and
        /// the matching echo-only residual metric.
        let doubleTalkSegmentScores: [DoubleTalkSegmentScore]
        /// Total frames successfully processed across far-end, near-end, and
        /// double-talk runs.
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

        var retentionDeviation: Float {
            max(abs(minRetention - 1), abs(maxRetention - 1))
        }

        var isEchoOnlyV14: Bool {
            label.localizedStandardContains("v1.4-aec")
        }
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
            let makeCandidateConditioner = {
                self.makeConditioner(libraryURL: libraryURL, modelURL: modelURL)
            }
            // Preflight: the factory falls back to an unavailable passthrough
            // (loaded == false) when the dylib/model can't instantiate. Fail with
            // one crisp message rather than scoring a bogus passthrough as the model.
            let preflight = makeCandidateConditioner()
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
                    makeConditioner: makeCandidateConditioner,
                    echoPath: echoPath))
            }
        }
        try XCTSkipIf(scores.isEmpty, "No candidate models loaded successfully.")

        printScoreTable(scores)
        let aggregates = aggregate(scores)
        printAggregates(aggregates)
        printDoubleTalkSegmentTable(scores)
        printDoubleTalkSegmentAggregates(scores)

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
        // Rule: best near-end retention at acceptable ERLE. If the robust axes tie,
        // prefer echo-only v1.4, then higher ERLE. Synthetic double-talk error is
        // reported, not selected on, because tone reshaping cannot certify fidelity.
        guard let chosen = viable.sorted(by: Self.prefersReleaseDefault).first else {
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
        makeConditioner: () -> any MicConditioning,
        echoPath: MeetingAecEchoPath
    ) -> ModelScore {
        // Far-end-only → ERLE (any mic energy is echo by construction).
        let farScenario = MeetingAecScenarioFactory.make(
            name: "far-end-only", nearEndActive: false, farEndActive: true, echoPath: echoPath)
        let farConditioner = makeConditioner()
        let farOut = MeetingAecRunner.run(farConditioner, scenario: farScenario)
        let farDiagnostics = farConditioner.diagnostics
        let farERLE = MeetingAecMetrics.erleDB(
            mic: farScenario.mic, output: farOut, over: farScenario.steadyStateWindow)

        // Near-end-only → must preserve the local voice's energy and not go silent.
        let nearScenario = MeetingAecScenarioFactory.make(
            name: "near-end-only", nearEndActive: true, farEndActive: false, echoPath: echoPath)
        let nearConditioner = makeConditioner()
        let nearOut = MeetingAecRunner.run(nearConditioner, scenario: nearScenario)
        let nearDiagnostics = nearConditioner.diagnostics
        let nearWindow = nearScenario.steadyStateWindow
        let nearErr = MeetingAecMetrics.nearEndErrorDB(
            output: nearOut, nearEnd: nearScenario.nearEnd, over: nearWindow)
        let retention = MeetingAecMetrics.rmsRatio(
            nearOut,
            reference: nearScenario.mic,
            over: nearWindow
        )

        // Double-talk → near-end error vs passthrough (reported, not gated).
        let dtScenario = MeetingAecScenarioFactory.make(
            name: "double-talk", nearEndActive: true, farEndActive: true, echoPath: echoPath)
        let dtConditioner = makeConditioner()
        let dtOut = MeetingAecRunner.run(dtConditioner, scenario: dtScenario)
        let dtDiagnostics = dtConditioner.diagnostics
        let dtWindow = dtScenario.steadyStateWindow
        let dtErr = MeetingAecMetrics.nearEndErrorDB(
            output: dtOut, nearEnd: dtScenario.nearEnd, over: dtWindow)
        let dtPass = MeetingAecRunner.run(PassthroughMicConditioner(), scenario: dtScenario)
        let dtPassErr = MeetingAecMetrics.nearEndErrorDB(
            output: dtPass, nearEnd: dtScenario.nearEnd, over: dtWindow)
        let overlapSweep = scoreDoubleTalkSegments(makeConditioner: makeConditioner, echoPath: echoPath)
        let diagnostics = [farDiagnostics, nearDiagnostics, dtDiagnostics] + overlapSweep.diagnostics

        return ModelScore(
            label: label, modelKey: modelKey, echoLabel: echoLabel,
            farEndERLE: farERLE,
            nearEndErrorDB: nearErr,
            nearEndRetentionRatio: retention,
            doubleTalkErrorDB: dtErr, doubleTalkPassthroughErrorDB: dtPassErr,
            doubleTalkSegmentScores: overlapSweep.scores,
            processedFrames: diagnostics.reduce(0) { $0 + $1.processedFrames },
            processingFailures: diagnostics.reduce(0) { $0 + $1.processingFailures },
            delaySamples: dtDiagnostics.currentDelaySamples)
    }

    private func scoreDoubleTalkSegments(
        makeConditioner: () -> any MicConditioning,
        echoPath: MeetingAecEchoPath
    ) -> OverlapSweepResult {
        var rows: [DoubleTalkSegmentScore] = []
        var diagnostics: [MeetingEchoSuppressionDiagnostics] = []
        for sir in Self.doubleTalkSignalToInterferenceDBs {
            let doubleTalk = MeetingAecScenarioFactory.makeDoubleTalk(
                name: "double-talk-\(Int(sir))db",
                echoPath: echoPath,
                signalToInterferenceDB: sir
            )
            let window = doubleTalk.steadyStateWindow
            let doubleTalkConditioner = makeConditioner()
            let cleaned = MeetingAecRunner.run(doubleTalkConditioner, scenario: doubleTalk)
            diagnostics.append(doubleTalkConditioner.diagnostics)
            let raw = MeetingAecRunner.run(PassthroughMicConditioner(), scenario: doubleTalk)
            let cleanError = MeetingAecMetrics.nearEndErrorDB(
                output: cleaned,
                nearEnd: doubleTalk.nearEnd,
                over: window
            )
            let rawError = MeetingAecMetrics.nearEndErrorDB(
                output: raw,
                nearEnd: doubleTalk.nearEnd,
                over: window
            )
            let cleanRetention = MeetingAecMetrics.rmsRatio(
                cleaned,
                reference: doubleTalk.nearEnd,
                over: window
            )
            let rawRetention = MeetingAecMetrics.rmsRatio(
                raw,
                reference: doubleTalk.nearEnd,
                over: window
            )

            let echoOnly = MeetingAecScenarioFactory.makeEchoOnlyAtDoubleTalkLevel(
                name: "echo-only-\(Int(sir))db",
                echoPath: echoPath,
                signalToInterferenceDB: sir
            )
            let echoWindow = echoOnly.steadyStateWindow
            let echoOnlyConditioner = makeConditioner()
            let echoCleaned = MeetingAecRunner.run(echoOnlyConditioner, scenario: echoOnly)
            diagnostics.append(echoOnlyConditioner.diagnostics)
            let echoRaw = MeetingAecRunner.run(PassthroughMicConditioner(), scenario: echoOnly)
            let echoCleanResidual = MeetingAecMetrics.relativePowerDB(
                signal: echoCleaned,
                reference: doubleTalk.nearEnd,
                over: echoWindow
            )
            let echoRawResidual = MeetingAecMetrics.relativePowerDB(
                signal: echoRaw,
                reference: doubleTalk.nearEnd,
                over: echoWindow
            )
            let echoERLE = MeetingAecMetrics.erleDB(
                mic: echoOnly.mic,
                output: echoCleaned,
                over: echoWindow
            )

            rows.append(DoubleTalkSegmentScore(
                signalToInterferenceDB: sir,
                cleanErrorDB: cleanError,
                rawErrorDB: rawError,
                cleanRetentionRatio: cleanRetention,
                rawRetentionRatio: rawRetention,
                echoOnlyCleanResidualDB: echoCleanResidual,
                echoOnlyRawResidualDB: echoRawResidual,
                echoOnlyERLE: echoERLE
            ))
        }
        return OverlapSweepResult(scores: rows, diagnostics: diagnostics)
    }

    private func makeConditioner(libraryURL: URL, modelURL: URL) -> any MicConditioning {
        MeetingEchoSuppressionFactory.makeConditioner(
            configuration: MeetingEchoSuppressionConfiguration(
                mode: .dynamicLibrary,
                libraryURL: libraryURL,
                modelURL: modelURL),
            bundle: Bundle(for: Self.self))
    }

    // MARK: Aggregation + reporting

    private struct SegmentAggregateKey: Hashable {
        let modelKey: String
        let signalToInterferenceDB: Double
    }

    private func aggregate(_ scores: [ModelScore]) -> [ModelAggregate] {
        // Group by full path, not filename, so a rebuilt model with the same
        // basename in another directory doesn't silently merge with the original.
        let byModel = Dictionary(grouping: scores, by: { $0.modelKey })
        return byModel.values.map { group -> ModelAggregate in
            let n = Double(group.count)
            let retentions = group.map { $0.nearEndRetentionRatio }
            return ModelAggregate(
                label: group.first?.label ?? "?",
                meanFarERLE: group.reduce(0.0) { $0 + $1.farEndERLE } / n,
                meanDoubleTalkError: group.reduce(0.0) { $0 + $1.doubleTalkErrorDB } / n,
                meanDoubleTalkImprovement: group.reduce(0.0) { $0 + $1.doubleTalkImprovement } / n,
                minRetention: retentions.min() ?? 0,
                maxRetention: retentions.max() ?? 0,
                meanNearError: group.reduce(0.0) { $0 + $1.nearEndErrorDB } / n,
                totalProcessingFailures: group.reduce(0) { $0 + $1.processingFailures })
        }
    }

    private static func prefersReleaseDefault(_ lhs: ModelAggregate, _ rhs: ModelAggregate) -> Bool {
        if lhs.retentionDeviation != rhs.retentionDeviation {
            return lhs.retentionDeviation < rhs.retentionDeviation
        }
        if lhs.isEchoOnlyV14 != rhs.isEchoOnlyV14 {
            return lhs.isEchoOnlyV14
        }
        if lhs.meanFarERLE != rhs.meanFarERLE {
            return lhs.meanFarERLE > rhs.meanFarERLE
        }
        return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
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

    private func printDoubleTalkSegmentTable(_ scores: [ModelScore]) {
        print("[AEC-SCORE] double-talk segment sweep (existing harness accuracy metric, not real-speech WER)")
        print("[AEC-SCORE] SIR is local-user speech vs reference bleed. echoResid is echo-only output"
            + " power relative to nominal local speech; lower should approach silence.")
        print(String(
            format: "  %-34@ %-11@ %4@ %8@ %9@ %8@ %8@ %8@ %9@ %10@ %8@",
            "model" as CVarArg, "echo" as CVarArg, "SIR" as CVarArg,
            "dtRaw" as CVarArg, "dtClean" as CVarArg, "dtImpr" as CVarArg,
            "rawRet" as CVarArg, "clnRet" as CVarArg,
            "echoRaw" as CVarArg, "echoClean" as CVarArg, "echoERLE" as CVarArg))
        for s in scores {
            for row in s.doubleTalkSegmentScores {
                print(String(
                    format: "  %-34@ %-11@ %+4.0f %8.1f %9.1f %8.1f %8.2f %8.2f %9.1f %10.1f %8.1f",
                    s.label as CVarArg,
                    s.echoLabel as CVarArg,
                    row.signalToInterferenceDB,
                    row.rawErrorDB,
                    row.cleanErrorDB,
                    row.improvementDB,
                    Double(row.rawRetentionRatio),
                    Double(row.cleanRetentionRatio),
                    row.echoOnlyRawResidualDB,
                    row.echoOnlyCleanResidualDB,
                    row.echoOnlyERLE
                ))
            }
        }
    }

    private func printDoubleTalkSegmentAggregates(_ scores: [ModelScore]) {
        let flattened = scores.flatMap { score in
            score.doubleTalkSegmentScores.map { row in
                (score: score, row: row)
            }
        }
        let grouped = Dictionary(grouping: flattened) { item in
            SegmentAggregateKey(
                modelKey: item.score.modelKey,
                signalToInterferenceDB: item.row.signalToInterferenceDB
            )
        }
        print("[AEC-SCORE] per-model double-talk aggregate by SIR (mean across echo paths):")
        for group in grouped.values.sorted(by: { lhs, rhs in
            let l = lhs.first
            let r = rhs.first
            if l?.score.label != r?.score.label {
                return (l?.score.label ?? "") < (r?.score.label ?? "")
            }
            if l?.score.modelKey != r?.score.modelKey {
                return (l?.score.modelKey ?? "") < (r?.score.modelKey ?? "")
            }
            return (l?.row.signalToInterferenceDB ?? 0) < (r?.row.signalToInterferenceDB ?? 0)
        }) {
            guard let first = group.first else { continue }
            let n = Double(group.count)
            let cleanError = group.reduce(0.0) { $0 + $1.row.cleanErrorDB } / n
            let rawError = group.reduce(0.0) { $0 + $1.row.rawErrorDB } / n
            let improvement = group.reduce(0.0) { $0 + $1.row.improvementDB } / n
            let echoClean = group.reduce(0.0) { $0 + $1.row.echoOnlyCleanResidualDB } / n
            let echoRaw = group.reduce(0.0) { $0 + $1.row.echoOnlyRawResidualDB } / n
            let echoERLE = group.reduce(0.0) { $0 + $1.row.echoOnlyERLE } / n
            let cleanRetention = group.reduce(0.0) { $0 + Double($1.row.cleanRetentionRatio) } / n
            print(String(
                format: "  %-34@ SIR %+4.0f  dtRaw %6.1f  dtClean %6.1f  dtImpr %6.1f  clnRet %.2f  echoRaw %6.1f  echoClean %6.1f  echoERLE %6.1f",
                first.score.label as CVarArg,
                first.row.signalToInterferenceDB,
                rawError,
                cleanError,
                improvement,
                cleanRetention,
                echoRaw,
                echoClean,
                echoERLE
            ))
        }
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
