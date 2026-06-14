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
        let root = URL(fileURLWithPath: expandTilde(fixturesDir), isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ValidationError("Fixtures directory does not exist: \(root.path)")
        }

        let fixtures = try fixtureDirectories(in: root)
        let defaultService = DiarizationService(config: .default)
        var exactServices: [Int: DiarizationService] = [:]

        var fixtureReports: [DiarizationEvalFixtureReport] = []
        for fixture in fixtures {
            guard let audioURL = try audioURL(in: fixture) else { continue }
            let expected = try expectedMetadata(in: fixture)
            let reference = try referenceSegments(in: fixture)
            printErr("Evaluating \(fixture.lastPathComponent)/\(audioURL.lastPathComponent)")

            var runs: [DiarizationEvalRunReport] = []
            runs.append(await evaluateRun(
                variant: "default",
                requestedSpeakers: nil,
                service: defaultService,
                audioURL: audioURL,
                expectedRemoteSpeakers: expected?.expectedRemoteSpeakers,
                reference: reference
            ))

            if let expectedSpeakers = expected?.expectedRemoteSpeakers, expectedSpeakers > 0 {
                let exactService = exactServices[expectedSpeakers] ?? DiarizationService(
                    speakerConstraint: .exact(expectedSpeakers)
                )
                exactServices[expectedSpeakers] = exactService
                runs.append(await evaluateRun(
                    variant: "exact(\(expectedSpeakers))",
                    requestedSpeakers: expectedSpeakers,
                    service: exactService,
                    audioURL: audioURL,
                    expectedRemoteSpeakers: expectedSpeakers,
                    reference: reference
                ))
            }

            fixtureReports.append(DiarizationEvalFixtureReport(
                fixture: fixture.lastPathComponent,
                audioFile: audioURL.lastPathComponent,
                expectedRemoteSpeakers: expected?.expectedRemoteSpeakers,
                referenceAvailable: reference != nil,
                runs: runs
            ))
        }

        return DiarizationEvalReport(
            schemaVersion: 1,
            fixturesDir: root.path,
            fixtureCount: fixtureReports.count,
            runCount: fixtureReports.reduce(0) { $0 + $1.runs.count },
            fixtures: fixtureReports
        )
    }

    private func evaluateRun(
        variant: String,
        requestedSpeakers: Int?,
        service: DiarizationService,
        audioURL: URL,
        expectedRemoteSpeakers: Int?,
        reference: [LabeledSegment]?
    ) async -> DiarizationEvalRunReport {
        do {
            let result = try await service.diarize(audioURL: audioURL)
            let hypothesis = result.segments.map(LabeledSegment.init)
            let der = reference.map {
                DiarizationMetrics.der(reference: $0, hypothesis: hypothesis)
            }
            let coverage = reference.map {
                DiarizationMetrics.coverage(reference: $0, hypothesis: hypothesis)
            }

            return DiarizationEvalRunReport(
                variant: variant,
                requestedSpeakers: requestedSpeakers,
                detectedSpeakers: result.speakerCount,
                speakerCountDelta: expectedRemoteSpeakers.map {
                    DiarizationMetrics.speakerCountDelta(expected: $0, detected: result.speakerCount)
                },
                segmentCount: result.segments.count,
                segmentSpeechMs: DiarizationMetrics.speechDuration(result.segments),
                der: der,
                coverage: coverage,
                error: nil
            )
        } catch {
            return DiarizationEvalRunReport(
                variant: variant,
                requestedSpeakers: requestedSpeakers,
                detectedSpeakers: nil,
                speakerCountDelta: nil,
                segmentCount: nil,
                segmentSpeechMs: nil,
                der: nil,
                coverage: nil,
                error: error.localizedDescription
            )
        }
    }

    private func fixtureDirectories(in root: URL) throws -> [URL] {
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

    private func audioURL(in fixture: URL) throws -> URL? {
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

    private func expectedMetadata(in fixture: URL) throws -> ExpectedMetadata? {
        let url = fixture.appendingPathComponent("expected.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ExpectedMetadata.self, from: data)
    }

    private func referenceSegments(in fixture: URL) throws -> [LabeledSegment]? {
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
}

private struct ExpectedMetadata: Decodable {
    let expectedRemoteSpeakers: Int?
}

private struct DiarizationEvalReport: Encodable {
    let schemaVersion: Int
    let fixturesDir: String
    let fixtureCount: Int
    let runCount: Int
    let fixtures: [DiarizationEvalFixtureReport]
}

private struct DiarizationEvalFixtureReport: Encodable {
    let fixture: String
    let audioFile: String
    let expectedRemoteSpeakers: Int?
    let referenceAvailable: Bool
    let runs: [DiarizationEvalRunReport]
}

private struct DiarizationEvalRunReport: Encodable {
    let variant: String
    let requestedSpeakers: Int?
    let detectedSpeakers: Int?
    let speakerCountDelta: Int?
    let segmentCount: Int?
    let segmentSpeechMs: Int?
    let der: DERBreakdown?
    let coverage: Double?
    let error: String?
}
