import AVFoundation
import CryptoKit
import XCTest

@testable import MacParakeetCore

final class TitaNetSpeakerEmbedderTests: XCTestCase {
    func testExclusiveRegionsDropOverlappedSpeech() {
        let segments = [
            SpeakerSegment(speakerId: "A", startMs: 0, endMs: 5_000),
            SpeakerSegment(speakerId: "B", startMs: 4_000, endMs: 6_000),
            SpeakerSegment(speakerId: "A", startMs: 5_500, endMs: 9_000),
            SpeakerSegment(speakerId: "B", startMs: 7_000, endMs: 7_500),
        ]
        XCTAssertEqual(
            TitaNetSpeakerEmbedder.exclusiveRegions(of: "A", in: segments),
            [0..<4_000, 6_000..<7_000, 7_500..<9_000]
        )
        XCTAssertEqual(TitaNetSpeakerEmbedder.exclusiveRegions(of: "B", in: segments), [5_000..<5_500])
    }

    func testSampleRegionsClampToAudioLength() {
        // 2 s of audio at 16 kHz; the second region runs past the end.
        XCTAssertEqual(
            TitaNetSpeakerEmbedder.sampleRegions([0..<100, 1_900..<5_000, 6_000..<7_000], limit: 32_000),
            [0..<1_600, 30_400..<32_000]
        )
    }

    func testFileRangesMapAWindowAcrossRegions() {
        let regions = [100..<200, 500..<550, 1_000..<1_300]
        // Concatenated: [0,100) -> 100..<200, [100,150) -> 500..<550, [150,450) -> 1000..<1300
        XCTAssertEqual(TitaNetSpeakerEmbedder.fileRanges(of: 50..<120, in: regions), [150..<200, 500..<520])
        XCTAssertEqual(TitaNetSpeakerEmbedder.fileRanges(of: 0..<450, in: regions), regions)
        XCTAssertEqual(TitaNetSpeakerEmbedder.fileRanges(of: 160..<170, in: regions), [1_010..<1_020])
    }

    /// Speech that is mostly overlapped yields no voiceprint, and the model is
    /// never even fetched for it.
    func testTooLittleExclusiveSpeechMakesNoVoiceprintAndNoDownload() async throws {
        let url = try writeSilence(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let fetches = FetchCounter()
        let embedder = TitaNetSpeakerEmbedder(
            modelDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            fetch: { _ in await fetches.increment(); throw URLError(.notConnectedToInternet) }
        )
        let voiceprints = try await embedder.voiceprints(
            audioURL: url,
            segments: [
                SpeakerSegment(speakerId: "A", startMs: 0, endMs: 9_000),  // 9 s active...
                SpeakerSegment(speakerId: "B", startMs: 1_000, endMs: 9_000),  // ...1 s alone
            ],
            speakers: ["A"]
        )
        XCTAssertTrue(voiceprints.isEmpty)
        let count = await fetches.count
        XCTAssertEqual(count, 0)
    }

    /// The hybrid withholds an embedding from an unclear speaker; the wrapper
    /// must not give it a voiceprint anyway.
    func testSpeakersWithoutAnInnerEmbeddingGetNoVoiceprint() async throws {
        let fetches = FetchCounter()
        let service = TitaNetVoiceprintDiarizationService(
            inner: StubDiarizer(withEmbedding: false),
            embedder: TitaNetSpeakerEmbedder(
                modelDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                fetch: { _ in await fetches.increment(); throw URLError(.notConnectedToInternet) }
            )
        )
        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/unused.wav"), speakerConstraint: nil)
        XCTAssertTrue(result.speakerEmbeddings.isEmpty)
        XCTAssertEqual(result.speechMsBySpeaker["S1"], 1_000)
        let count = await fetches.count
        XCTAssertEqual(count, 0)
    }

    func testVoiceprintSpeechFallsBackToActivity() {
        let result = MacParakeetDiarizationResult(
            segments: [], speakerCount: 2, speakers: [],
            speechMsBySpeaker: ["A": 20_000, "B": 9_000], voiceprintSpeechMsBySpeaker: ["A": 4_000]
        )
        XCTAssertEqual(result.voiceprintSpeechSeconds(forSpeaker: "A"), 4)
        XCTAssertEqual(result.voiceprintSpeechSeconds(forSpeaker: "B"), 9)
    }

    func testClearModelCachesRemovesTheVoiceprintModel() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = TitaNetSpeakerEmbedder.modelCacheRoot(directory: base).appendingPathComponent("v1/x")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        DiarizationServiceFactory.clearModelCaches(directory: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TitaNetSpeakerEmbedder.modelCacheRoot(directory: base).path))
    }

    /// The file-backed path the embedder reads windows through: exact samples
    /// for each range, in order, across disjoint stretches of the file.
    func testSpeechAudioReadsTheRequestedRangesFromTheFile() throws {
        let url = try writeRamp(samples: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try SpeechAudio(url: url)
        XCTAssertEqual(audio.count, 48_000)
        let samples = try audio.samples(for: [10..<13, 40_000..<40_002])
        XCTAssertEqual(samples, [10, 11, 12, 40_000, 40_001].map { Float($0) / 65_536 })
    }

    /// Two embedders on one directory (the factory makes one per service)
    /// share a single download.
    func testConcurrentEmbeddersShareOneInstall() async throws {
        let archive = try fixtureArchive()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetches = FetchCounter()
        func make() -> TitaNetSpeakerEmbedder {
            TitaNetSpeakerEmbedder(
                modelDirectory: directory, archiveBytes: archive.data.count, archiveSHA256: archive.sha256,
                fetch: { _ in
                    await fetches.increment()
                    try await Task.sleep(nanoseconds: 200_000_000)
                    return archive.data
                }
            )
        }
        let first = make()
        let second = make()
        async let a: Void = first.prepareModel()
        async let b: Void = second.prepareModel()
        _ = try await (a, b)
        let count = await fetches.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(first.isModelAvailable())
    }

    private func writeRamp(samples: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<samples { buffer.floatChannelData![0][index] = Float(index) / 65_536 }
        try file.write(from: buffer)
        return url
    }

    private func writeSilence(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    func testWindowsDropShortTailUnlessAlone() {
        let w = TitaNetSpeakerEmbedder.windowSamples
        XCTAssertEqual(TitaNetSpeakerEmbedder.windows(count: 0), [])
        XCTAssertEqual(TitaNetSpeakerEmbedder.windows(count: 8_000), [0..<8_000])
        XCTAssertEqual(TitaNetSpeakerEmbedder.windows(count: w + 10_000), [0..<w])
        XCTAssertEqual(TitaNetSpeakerEmbedder.windows(count: w + 30_000), [0..<w, w..<(w + 30_000)])
    }

    func testPaddingKeepsCosineDistance() throws {
        let identity = SpeakerVoiceprintModel.identity
        var a = [Float](repeating: 0, count: 192)
        var b = [Float](repeating: 0, count: 192)
        a[0] = 1
        b[0] = 1
        b[1] = 1
        let ea = try XCTUnwrap(SpeakerEmbedding(rawVector: TitaNetSpeakerEmbedder.padded(a), identity: identity))
        let eb = try XCTUnwrap(SpeakerEmbedding(rawVector: TitaNetSpeakerEmbedder.padded(b), identity: identity))
        XCTAssertEqual(try XCTUnwrap(ea.cosineDistance(to: eb)), 1 - 1 / 2.0.squareRoot(), accuracy: 1e-6)
    }

    func testTitaNetVectorsNeverCompareWithWeSpeaker() throws {
        let vector = [Float](repeating: 1, count: SpeakerEmbedding.dimension)
        let titanet = try XCTUnwrap(SpeakerEmbedding(rawVector: vector, identity: SpeakerVoiceprintModel.identity))
        let wespeaker = try XCTUnwrap(SpeakerEmbedding(rawVector: vector, identity: DiarizationService.defaultModelIdentity))
        XCTAssertNil(titanet.cosineDistance(to: wespeaker))
    }

    func testMissingModelLeavesNoEmbeddingsButKeepsSegments() async throws {
        let inner = StubDiarizer()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = TitaNetVoiceprintDiarizationService(
            inner: inner,
            embedder: TitaNetSpeakerEmbedder(
                modelDirectory: missing, fetch: { _ in throw URLError(.notConnectedToInternet) }
            )
        )
        let result = try await service.diarize(audioURL: URL(fileURLWithPath: "/unused.wav"), speakerConstraint: nil)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.speechMsBySpeaker["S1"], 1_000)
        XCTAssertTrue(result.speakerEmbeddings.isEmpty)
    }

    /// A zip of a stand-in package, with its real size and digest.
    private func fixtureArchive() throws -> (data: Data, sha256: String) {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("TitaNetLarge.mlpackage", isDirectory: true)
        try files.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        let zip = root.appendingPathComponent("model.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", package.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let data = try Data(contentsOf: zip)
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testPrepareModelInstallsAVerifiedArchiveOnce() async throws {
        let archive = try fixtureArchive()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fetches = FetchCounter()
        let embedder = TitaNetSpeakerEmbedder(
            modelDirectory: directory, archiveBytes: archive.data.count, archiveSHA256: archive.sha256,
            fetch: { _ in await fetches.increment(); return archive.data }
        )
        try await embedder.prepareModel()
        try await embedder.prepareModel()
        XCTAssertTrue(embedder.isModelAvailable())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: embedder.packageURL.appendingPathComponent("Manifest.json").path))
        let count = await fetches.count
        XCTAssertEqual(count, 1)
    }

    func testPrepareModelRejectsATamperedArchive() async throws {
        let archive = try fixtureArchive()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let embedder = TitaNetSpeakerEmbedder(
            modelDirectory: directory, archiveBytes: archive.data.count,
            archiveSHA256: String(repeating: "0", count: 64),
            fetch: { _ in archive.data }
        )
        do {
            try await embedder.prepareModel()
            XCTFail("a digest mismatch must not install")
        } catch TitaNetSpeakerEmbedderError.invalidModelArchive {}
        XCTAssertFalse(embedder.isModelAvailable())
    }
}

private actor FetchCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor StubDiarizer: DiarizationServiceProtocol {
    let withEmbedding: Bool
    init(withEmbedding: Bool = true) { self.withEmbedding = withEmbedding }

    func diarize(
        audioURL: URL, speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        let vector = [Float](repeating: 1, count: SpeakerEmbedding.dimension)
        return MacParakeetDiarizationResult(
            segments: [SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1_000)],
            speakerCount: 1,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")],
            speakerEmbeddings: withEmbedding
                ? ["S1": SpeakerEmbedding(rawVector: vector, identity: DiarizationService.defaultModelIdentity)!] : [:],
            speechMsBySpeaker: ["S1": 1_000]
        )
    }
    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {}
    func isReady() async -> Bool { true }
}
