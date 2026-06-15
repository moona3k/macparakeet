import ArgumentParser
import Foundation
import MacParakeetCore

struct DiarizationEvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarization-eval",
        abstract: "Run local speaker diarization against private audio fixtures."
    )

    @Argument(help: "Directory whose immediate subdirectories contain private diarization fixtures.")
    var fixturesDir: String

    @Flag(name: .long, help: "Emit JSON instead of a compact table.")
    var json: Bool = false

    @Option(name: .long, help: "Full-width diarization scoring collar in milliseconds. Default: 0.")
    var collarMs: Int = 0

    @Flag(name: [.customLong("ignore-overlap"), .customLong("skip-overlap")], help: "Skip reference overlap regions when scoring DER and coverage.")
    var ignoreOverlap: Bool = false

    mutating func validate() throws {
        guard collarMs >= 0 else {
            throw ValidationError("--collar-ms must be non-negative.")
        }
    }

    func run() async throws {
        try await emitJSONOrRethrow(json: json) {
            let report = try await evaluate()
            if json {
                try printJSON(report)
            } else {
                printTable(report)
            }
        }
    }

    private func evaluate() async throws -> DiarizationEvalReport {
        try await Self.evaluate(
            fixturesDir: fixturesDir,
            scoringOptions: DiarizationScoringOptions(collarMs: collarMs, skipOverlap: ignoreOverlap),
            service: DiarizationService(config: .default)
        )
    }

    static func evaluate(
        fixturesDir: String,
        scoringOptions: DiarizationScoringOptions,
        service: any DiarizationServiceProtocol
    ) async throws -> DiarizationEvalReport {
        let root = URL(fileURLWithPath: expandTilde(fixturesDir), isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ValidationError("Fixtures directory does not exist: \(root.path)")
        }

        let fixtures = try Self.fixtureDirectories(in: root)

        var fixtureReports: [DiarizationEvalFixtureReport] = []
        for fixture in fixtures {
            guard let audioURL = try Self.audioURL(in: fixture) else { continue }
            let expected = try Self.expectedMetadata(in: fixture)
            let reference = try Self.referenceSegments(in: fixture)
            printErr("Evaluating \(fixture.lastPathComponent)")

            var runs: [DiarizationEvalRunReport] = []
            for variant in Self.evalVariants(expected: expected) {
                runs.append(await Self.evaluateRun(
                    variant: variant.name,
                    options: variant.options,
                    service: service,
                    audioURL: audioURL,
                    expectedRemoteSpeakers: expected?.expectedRemoteSpeakers,
                    reference: reference,
                    scoringOptions: scoringOptions
                ))
            }

            fixtureReports.append(DiarizationEvalFixtureReport(
                fixture: fixture.lastPathComponent,
                audioFile: nil,
                expectedRemoteSpeakers: expected?.expectedRemoteSpeakers,
                referenceAvailable: reference != nil,
                runs: runs
            ))
        }

        return DiarizationEvalReport(
            schemaVersion: 1,
            fixturesDir: nil,
            scoringOptions: scoringOptions,
            fixtureCount: fixtureReports.count,
            runCount: fixtureReports.reduce(0) { $0 + $1.runs.count },
            fixtures: fixtureReports
        )
    }

    private static func evaluateRun(
        variant: String,
        options: DiarizationOptions,
        service: any DiarizationServiceProtocol,
        audioURL: URL,
        expectedRemoteSpeakers: Int?,
        reference: [LabeledSegment]?,
        scoringOptions: DiarizationScoringOptions
    ) async -> DiarizationEvalRunReport {
        do {
            let result = try await service.diarize(audioURL: audioURL, options: options)
            let hypothesis = result.segments.map(LabeledSegment.init)
            let der = reference.map {
                DiarizationMetrics.der(reference: $0, hypothesis: hypothesis, options: scoringOptions)
            }
            let coverage = reference.map {
                DiarizationMetrics.coverage(reference: $0, hypothesis: hypothesis, options: scoringOptions)
            }
            let qualityReport = DiarizationQualityReport(
                transcriptionSourceType: .file,
                diarizedAudioSource: nil,
                requestedSpeakerHint: options.speakerCountHint,
                diarizationResult: result,
                assignmentSummary: emptyAssignmentSummary
            )

            return DiarizationEvalRunReport(
                variant: variant,
                requestedSpeakers: options.speakerCountHint?.exact,
                requestedSpeakerHint: options.speakerCountHint,
                detectedSpeakers: result.speakerCount,
                speakerCountDelta: expectedRemoteSpeakers.map {
                    DiarizationMetrics.speakerCountDelta(expected: $0, detected: result.speakerCount)
                },
                segmentCount: result.segments.count,
                segmentSpeechMs: DiarizationMetrics.speechDuration(result.segments),
                der: der,
                coverage: coverage,
                qualityReport: qualityReport,
                error: nil
            )
        } catch {
            return DiarizationEvalRunReport(
                variant: variant,
                requestedSpeakers: options.speakerCountHint?.exact,
                requestedSpeakerHint: options.speakerCountHint,
                detectedSpeakers: nil,
                speakerCountDelta: nil,
                segmentCount: nil,
                segmentSpeechMs: nil,
                der: nil,
                coverage: nil,
                qualityReport: nil,
                error: error.localizedDescription
            )
        }
    }

    static func evalVariants(expected: ExpectedMetadata?) -> [EvalVariant] {
        var variants = [
            EvalVariant(name: "default", options: .default),
        ]

        if let exact = Self.positive(expected?.expectedRemoteSpeakers) {
            variants.append(EvalVariant(
                name: "exact(\(exact))",
                options: DiarizationOptions(speakerCountHint: SpeakerCountHint(exact: exact))
            ))
        }

        if let minimum = Self.positive(expected?.minimumRemoteSpeakers ?? expected?.expectedRemoteSpeakers) {
            variants.append(EvalVariant(
                name: "min(\(minimum))",
                options: DiarizationOptions(speakerCountHint: SpeakerCountHint(minimum: minimum))
            ))
        }

        if let maximum = Self.positive(expected?.maximumRemoteSpeakers ?? expected?.expectedRemoteSpeakers) {
            variants.append(EvalVariant(
                name: "max(\(maximum))",
                options: DiarizationOptions(speakerCountHint: SpeakerCountHint(maximum: maximum))
            ))
        }

        var seen = Set<String>()
        return variants.filter { variant in
            let key = "\(variant.name):\(String(describing: variant.options.speakerCountHint))"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func fixtureDirectories(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func audioURL(in fixture: URL) throws -> URL? {
        for preferredName in ["system.wav", "audio.wav"] {
            let candidate = fixture.appendingPathComponent(preferredName, isDirectory: false)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }

        return try FileManager.default.contentsOfDirectory(
            at: fixture,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .first
    }

    private static func expectedMetadata(in fixture: URL) throws -> ExpectedMetadata? {
        let url = fixture.appendingPathComponent("expected.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ExpectedMetadata.self, from: data)
    }

    private static func referenceSegments(in fixture: URL) throws -> [LabeledSegment]? {
        let url = fixture.appendingPathComponent("reference.rttm", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try RTTMParser.parse(contents)
    }

    private func printTable(_ report: DiarizationEvalReport) {
        guard !report.fixtures.isEmpty else {
            print("No fixture subdirectories with .wav audio found.")
            return
        }

        print("scoring: collar_ms=\(report.scoringOptions.collarMs) skip_overlap=\(report.scoringOptions.skipOverlap)")
        print(
            [
                padded("fixture", 26),
                padded("run", 10),
                padded("spk", 4),
                padded("delta", 6),
                padded("seg", 5),
                padded("speech_s", 9),
                padded("DER", 8),
                padded("coverage", 9),
                padded("warn", 5),
            ].joined(separator: " ")
        )

        for fixture in report.fixtures {
            for run in fixture.runs {
                if let error = run.error {
                    print(
                        [
                            padded(fixture.fixture, 26),
                            padded(run.variant, 10),
                            padded("ERROR", 4),
                            padded("--", 6),
                            padded("--", 5),
                            padded("--", 9),
                            padded("--", 8),
                            padded("--", 9),
                            padded("--", 5),
                            error,
                        ].joined(separator: " ")
                    )
                    continue
                }

                print(
                    [
                        padded(fixture.fixture, 26),
                        padded(run.variant, 10),
                        padded(run.detectedSpeakers.map(String.init) ?? "--", 4),
                        padded(formatDelta(run.speakerCountDelta), 6),
                        padded(run.segmentCount.map(String.init) ?? "--", 5),
                        padded(formatSeconds(run.segmentSpeechMs), 9),
                        padded(formatDouble(run.der?.der), 8),
                        padded(formatDouble(run.coverage), 9),
                        padded(run.qualityReport.map { String($0.warnings.count) } ?? "--", 5),
                    ].joined(separator: " ")
                )
            }
        }
    }

    private func padded(_ value: String, _ width: Int) -> String {
        let display = value.count > width ? String(value.prefix(width - 1)) + "." : value
        return display + String(repeating: " ", count: max(0, width - display.count))
    }

    private func formatDelta(_ value: Int?) -> String {
        guard let value else { return "--" }
        return value >= 0 ? "+\(value)" : "\(value)"
    }

    private func formatSeconds(_ value: Int?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", Double(value) / 1000.0)
    }

    private func formatDouble(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.3f", value)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static let emptyAssignmentSummary = WordSpeakerAssignmentSummary(
        totalWords: 0,
        directOverlapWords: 0,
        fallbackNearestWords: 0,
        sourceOnlyWords: 0,
        unassignedWords: 0,
        fallbackToleranceMs: 250,
        ambiguityMarginMs: 150,
        minFallbackQualityScore: 0.60
    )
}

struct ExpectedMetadata: Decodable {
    let expectedRemoteSpeakers: Int?
    let minimumRemoteSpeakers: Int?
    let maximumRemoteSpeakers: Int?
}

struct EvalVariant {
    let name: String
    let options: DiarizationOptions
}

struct DiarizationEvalReport: Encodable {
    let schemaVersion: Int
    let fixturesDir: String?
    let scoringOptions: DiarizationScoringOptions
    let fixtureCount: Int
    let runCount: Int
    let fixtures: [DiarizationEvalFixtureReport]
}

struct DiarizationEvalFixtureReport: Encodable {
    let fixture: String
    let audioFile: String?
    let expectedRemoteSpeakers: Int?
    let referenceAvailable: Bool
    let runs: [DiarizationEvalRunReport]
}

struct DiarizationEvalRunReport: Encodable {
    let variant: String
    let requestedSpeakers: Int?
    let requestedSpeakerHint: SpeakerCountHint?
    let detectedSpeakers: Int?
    let speakerCountDelta: Int?
    let segmentCount: Int?
    let segmentSpeechMs: Int?
    let der: DERBreakdown?
    let coverage: Double?
    let qualityReport: DiarizationQualityReport?
    let error: String?
}
