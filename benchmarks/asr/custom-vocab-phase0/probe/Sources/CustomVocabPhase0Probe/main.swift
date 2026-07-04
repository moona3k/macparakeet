import AVFoundation
import CoreML
import FluidAudio
import Foundation

struct ManifestEntry: Decodable {
    let id: String
    let ref: String
    let audio: String
    let terms: [String]?
    let voice: String?
    let rate: Int?
}

struct ReplacementRecord: Encodable {
    let originalWord: String
    let originalScore: Float
    let replacementWord: String?
    let replacementScore: Float?
    let shouldReplace: Bool
    let reason: String
}

struct ProbeRecord: Encodable {
    let id: String
    let ref: String
    let hyp: String
    let dataset: String
    let engine: String
    let audio_s: Double
    let input_audio_s: Double
    let proc_s: Double
    let rtfx: Double
    let boost_requested: Bool
    let boost_supported: Bool
    let unsupported_reason: String?
    let raw_hyp: String?
    let ctc_detected_terms: [String]
    let ctc_applied_terms: [String]
    let replacements: [ReplacementRecord]
    let append_silence_s: Double
    let terms: [String]?
}

struct Arguments {
    var engine: String?
    var manifest: String?
    var output: String?
    var dataset = "phase0"
    var vocab: String?
    var limit: Int?
    var appendSilenceSeconds: Double = 0
    var minSimilarity: Float?
    var cbw: Float?
    var marginSeconds: Double?
}

struct VocabularyBoost {
    let vocabulary: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
}

enum ProbeError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        }
    }
}

@main
struct CustomVocabPhase0Probe {
    static func main() async throws {
        do {
            let args = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            try await run(args)
        } catch let error as ProbeError {
            fputs("\(error.description)\n\n\(usage())\n", stderr)
            Foundation.exit(2)
        } catch {
            fputs("error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run(_ args: Arguments) async throws {
        guard let engine = args.engine else { throw ProbeError.usage("missing --engine") }
        guard let manifestPath = args.manifest else { throw ProbeError.usage("missing --manifest") }
        guard let outputPath = args.output else { throw ProbeError.usage("missing --output") }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        var entries = try readManifest(manifestURL)
        if let limit = args.limit {
            entries = Array(entries.prefix(limit))
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        let boost = try await loadVocabularyBoostIfNeeded(args.vocab)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let converter = AudioConverter()

        switch engine {
        case "tdt-v2", "tdt-v3", "tdt-110m":
            let version = try modelVersion(for: engine)
            try await runTDT(
                version: version,
                engineName: engine,
                entries: entries,
                manifestURL: manifestURL,
                outputHandle: handle,
                encoder: encoder,
                converter: converter,
                boost: boost,
                args: args
            )
        case "unified":
            try await runUnified(
                entries: entries,
                manifestURL: manifestURL,
                outputHandle: handle,
                encoder: encoder,
                converter: converter,
                boost: boost,
                args: args
            )
        default:
            throw ProbeError.usage("unsupported --engine \(engine)")
        }
    }

    static func runTDT(
        version: AsrModelVersion,
        engineName: String,
        entries: [ManifestEntry],
        manifestURL: URL,
        outputHandle: FileHandle,
        encoder: JSONEncoder,
        converter: AudioConverter,
        boost: VocabularyBoost?,
        args: Arguments
    ) async throws {
        progress("loading \(engineName) models")
        let models = try await AsrModels.downloadAndLoad(version: version)
        let config = ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId),
            encoderHiddenSize: version.encoderHiddenSize
        )
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)

        for (index, entry) in entries.enumerated() {
            progress("[\(index + 1)/\(entries.count)] \(entry.id) \(engineName)")
            let audioURL = resolveAudioURL(entry.audio, relativeTo: manifestURL)
            let originalSamples = try converter.resampleAudioFile(audioURL)
            let samples = appendSilence(originalSamples, seconds: args.appendSilenceSeconds)
            var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)

            let started = Date()
            let rawResult = try await manager.transcribe(samples, decoderState: &decoderState)
            let rawText = rawResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            var hyp = rawText
            var detected: [String] = []
            var applied: [String] = []
            var replacements: [ReplacementRecord] = []
            var boostSupported = false
            var unsupportedReason: String?

            if let boost {
                let spotResult = try await boost.spotter.spotKeywordsWithLogProbs(
                    audioSamples: samples,
                    customVocabulary: boost.vocabulary
                )
                detected = uniquePreservingOrder(spotResult.detections.map { $0.term.text })
                if let tokenTimings = rawResult.tokenTimings, !tokenTimings.isEmpty {
                    boostSupported = true
                    let sizeConfig = ContextBiasingConstants.rescorerConfig(
                        forVocabSize: boost.vocabulary.terms.count
                    )
                    let output = boost.rescorer.ctcTokenRescore(
                        transcript: rawText,
                        tokenTimings: tokenTimings,
                        logProbs: spotResult.logProbs,
                        frameDuration: spotResult.frameDuration,
                        cbw: args.cbw ?? sizeConfig.cbw,
                        marginSeconds: args.marginSeconds ?? ContextBiasingConstants.defaultMarginSeconds,
                        minSimilarity: args.minSimilarity ?? sizeConfig.minSimilarity
                    )
                    hyp = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    applied = uniquePreservingOrder(
                        output.replacements.compactMap { replacement in
                            replacement.shouldReplace ? replacement.replacementWord : nil
                        }
                    )
                    replacements = output.replacements.map {
                        ReplacementRecord(
                            originalWord: $0.originalWord,
                            originalScore: $0.originalScore,
                            replacementWord: $0.replacementWord,
                            replacementScore: $0.replacementScore,
                            shouldReplace: $0.shouldReplace,
                            reason: $0.reason
                        )
                    }
                } else {
                    unsupportedReason =
                        "TDT transcript did not include token timings; skipping VocabularyRescorer.ctcTokenRescore."
                }
            }

            let proc = Date().timeIntervalSince(started)
            let record = ProbeRecord(
                id: entry.id,
                ref: entry.ref,
                hyp: hyp,
                dataset: args.dataset,
                engine: engineName,
                audio_s: Double(originalSamples.count) / 16_000.0,
                input_audio_s: Double(samples.count) / 16_000.0,
                proc_s: proc,
                rtfx: Double(samples.count) / 16_000.0 / proc,
                boost_requested: boost != nil,
                boost_supported: boostSupported,
                unsupported_reason: unsupportedReason,
                raw_hyp: boost == nil ? nil : rawText,
                ctc_detected_terms: detected,
                ctc_applied_terms: applied,
                replacements: replacements,
                append_silence_s: args.appendSilenceSeconds,
                terms: entry.terms
            )
            try write(record, to: outputHandle, encoder: encoder)
        }
    }

    static func runUnified(
        entries: [ManifestEntry],
        manifestURL: URL,
        outputHandle: FileHandle,
        encoder: JSONEncoder,
        converter: AudioConverter,
        boost: VocabularyBoost?,
        args: Arguments
    ) async throws {
        progress("loading unified models")
        let manager = UnifiedAsrManager()
        try await manager.loadModels()

        for (index, entry) in entries.enumerated() {
            progress("[\(index + 1)/\(entries.count)] \(entry.id) unified")
            let audioURL = resolveAudioURL(entry.audio, relativeTo: manifestURL)
            let originalSamples = try converter.resampleAudioFile(audioURL)
            let samples = appendSilence(originalSamples, seconds: args.appendSilenceSeconds)
            let started = Date()
            let hyp = try await manager.transcribe(samples)

            var detected: [String] = []
            if let boost {
                let spotResult = try await boost.spotter.spotKeywordsWithLogProbs(
                    audioSamples: samples,
                    customVocabulary: boost.vocabulary
                )
                detected = uniquePreservingOrder(spotResult.detections.map { $0.term.text })
            }

            let proc = Date().timeIntervalSince(started)
            let record = ProbeRecord(
                id: entry.id,
                ref: entry.ref,
                hyp: hyp.trimmingCharacters(in: .whitespacesAndNewlines),
                dataset: args.dataset,
                engine: "unified",
                audio_s: Double(originalSamples.count) / 16_000.0,
                input_audio_s: Double(samples.count) / 16_000.0,
                proc_s: proc,
                rtfx: Double(samples.count) / 16_000.0 / proc,
                boost_requested: boost != nil,
                boost_supported: false,
                unsupported_reason: boost == nil
                    ? nil
                    : "UnifiedAsrManager.transcribe returns text only; VocabularyRescorer.ctcTokenRescore requires TDT token timings.",
                raw_hyp: nil,
                ctc_detected_terms: detected,
                ctc_applied_terms: [],
                replacements: [],
                append_silence_s: args.appendSilenceSeconds,
                terms: entry.terms
            )
            try write(record, to: outputHandle, encoder: encoder)
        }
    }

    static func loadVocabularyBoostIfNeeded(_ path: String?) async throws -> VocabularyBoost? {
        guard let path else { return nil }
        progress("loading vocabulary and CTC scorer")
        let loaded = try await CustomVocabularyContext.loadWithCtcTokens(from: path)
        let spotter = CtcKeywordSpotter(models: loaded.models)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: loaded.vocab,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m)
        )
        return VocabularyBoost(vocabulary: loaded.vocab, spotter: spotter, rescorer: rescorer)
    }

    static func readManifest(_ url: URL) throws -> [ManifestEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(ManifestEntry.self, from: Data(line.utf8))
        }
    }

    static func write(_ record: ProbeRecord, to handle: FileHandle, encoder: JSONEncoder) throws {
        let data = try encoder.encode(record)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    static func resolveAudioURL(_ audio: String, relativeTo manifestURL: URL) -> URL {
        if audio.hasPrefix("/") {
            return URL(fileURLWithPath: audio)
        }
        return manifestURL.deletingLastPathComponent().appendingPathComponent(audio).standardizedFileURL
    }

    static func appendSilence(_ samples: [Float], seconds: Double) -> [Float] {
        guard seconds > 0 else { return samples }
        let extra = max(0, Int((seconds * 16_000).rounded()))
        guard extra > 0 else { return samples }
        return samples + Array(repeating: 0, count: extra)
    }

    static func modelVersion(for engine: String) throws -> AsrModelVersion {
        switch engine {
        case "tdt-v2": return .v2
        case "tdt-v3": return .v3
        case "tdt-110m": return .tdtCtc110m
        default: throw ProbeError.usage("unsupported TDT engine \(engine)")
        }
    }

    static func parseArguments(_ raw: [String]) throws -> Arguments {
        var args = Arguments()
        var index = 0
        while index < raw.count {
            let flag = raw[index]
            func value() throws -> String {
                let next = index + 1
                guard next < raw.count else { throw ProbeError.usage("missing value for \(flag)") }
                index += 2
                return raw[next]
            }

            switch flag {
            case "--engine": args.engine = try value()
            case "--manifest": args.manifest = try value()
            case "--output": args.output = try value()
            case "--dataset": args.dataset = try value()
            case "--vocab": args.vocab = try value()
            case "--limit": args.limit = try parseInt(try value(), flag: flag)
            case "--append-silence-seconds": args.appendSilenceSeconds = try parseDouble(try value(), flag: flag)
            case "--min-similarity": args.minSimilarity = try parseFloat(try value(), flag: flag)
            case "--cbw": args.cbw = try parseFloat(try value(), flag: flag)
            case "--margin-seconds": args.marginSeconds = try parseDouble(try value(), flag: flag)
            case "--help", "-h": throw ProbeError.usage("")
            default: throw ProbeError.usage("unknown argument \(flag)")
            }
        }
        return args
    }

    static func parseInt(_ raw: String, flag: String) throws -> Int {
        guard let value = Int(raw) else {
            throw ProbeError.usage("invalid integer for \(flag): \(raw)")
        }
        return value
    }

    static func parseDouble(_ raw: String, flag: String) throws -> Double {
        guard let value = Double(raw) else {
            throw ProbeError.usage("invalid number for \(flag): \(raw)")
        }
        return value
    }

    static func parseFloat(_ raw: String, flag: String) throws -> Float {
        guard let value = Float(raw) else {
            throw ProbeError.usage("invalid number for \(flag): \(raw)")
        }
        return value
    }

    static func usage() -> String {
        """
        Usage:
          custom-vocab-phase0-probe --engine tdt-v3|tdt-v2|tdt-110m|unified \\
            --manifest PATH --output PATH [--dataset NAME] [--vocab PATH] \\
            [--limit N] [--append-silence-seconds S] [--min-similarity F] \\
            [--cbw F] [--margin-seconds S]
        """
    }

    static func progress(_ message: String) {
        fputs("[custom-vocab-phase0] \(message)\n", stderr)
    }

    static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }
}
