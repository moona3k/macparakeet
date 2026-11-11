import XCTest
@testable import MacParakeetCore

/// The microphone track's own voices: the owner, room voices and echo of the
/// call, and how the finalizer attributes microphone words to them.
final class MeetingMicrophoneSpeakerTests: XCTestCase {
    private let identity = SpeakerModelIdentity(
        embeddingModelId: "test-model",
        aggregationProfileId: "test-aggregation"
    )

    // MARK: Resolver

    func testSingleVoiceHeadsetMeetingIsTheOwnerAlone() {
        let resolution = resolve(
            microphone: [voice("S1", 0, seconds: 120)]
        )

        XCTAssertEqual(resolution.ownerObservation?.speakerId, "microphone")
        XCTAssertEqual(resolution.ownerObservation?.captureDomain, .microphone)
        XCTAssertTrue(resolution.roomSpeakers.isEmpty)
        XCTAssertTrue(resolution.echoTargets.isEmpty)
        XCTAssertEqual(Set(resolution.segments.map(\.speakerId)), ["microphone"])
    }

    /// The far end playing through speakers comes back on the microphone. It
    /// must be credited to that participant, and never chosen as the owner,
    /// even when it out-talks them.
    func testEchoOfACallParticipantGoesToTheirClusterNotTheOwner() {
        let resolution = resolve(
            microphone: [voice("S1", 0, seconds: 40), voice("S2", 5, degrees: 15, seconds: 90)],
            system: [voice("S1", 5, seconds: 100)]
        )

        XCTAssertEqual(resolution.echoTargets, ["S2": "system:S1"])
        XCTAssertEqual(resolution.ownerObservation?.speechSeconds, 40)
        XCTAssertTrue(resolution.roomSpeakers.isEmpty)
        XCTAssertEqual(resolution.segments.first { $0.startMs == 1_000 }?.speakerId, "system:S1")
    }

    func testWithoutASavedVoiceTheMostSpeechIsTheOwnerAndOthersAreRoomVoices() {
        let resolution = resolve(
            microphone: [voice("S1", 0, seconds: 20), voice("S2", 1, seconds: 60)]
        )

        XCTAssertEqual(resolution.ownerObservation?.speechSeconds, 60)
        XCTAssertEqual(resolution.roomSpeakers, [SpeakerInfo(id: "microphone:S1", label: "Room 1")])
        XCTAssertEqual(resolution.roomObservations.map(\.speakerId), ["microphone:S1"])
        XCTAssertEqual(resolution.roomObservations.first?.captureDomain, .microphone)
        XCTAssertNil(resolution.ownerDistance)
    }

    /// The case enrolling a voice is for: a colleague in the room talks more
    /// than the owner, and the saved voice still picks the owner out.
    func testSavedVoiceChoosesTheOwnerOverAColleagueWhoTalksMore() {
        let resolution = resolve(
            microphone: [voice("S1", 0, degrees: 10, seconds: 20), voice("S2", 1, seconds: 60)],
            owner: profile(voice: 0)
        )

        XCTAssertEqual(resolution.ownerObservation?.speechSeconds, 20)
        XCTAssertEqual(resolution.roomSpeakers.map(\.id), ["microphone:S2"])
        XCTAssertEqual(try XCTUnwrap(resolution.ownerDistance), 1 - cos(10 * Double.pi / 180), accuracy: 1e-4)
    }

    /// A saved voice that matches nobody does not invent an owner: the most
    /// speech still decides, and the distance records the miss.
    func testSavedVoiceThatMatchesNobodyFallsBackToMostSpeech() {
        let resolution = resolve(
            microphone: [voice("S1", 1, seconds: 60)],
            owner: profile(voice: 0)
        )

        XCTAssertEqual(resolution.ownerObservation?.speechSeconds, 60)
        XCTAssertEqual(try XCTUnwrap(resolution.ownerDistance), 1, accuracy: 1e-4)
    }

    func testShortFragmentsFoldIntoTheOwner() {
        let resolution = resolve(
            microphone: [voice("S1", 0, seconds: 60), voice("S2", 1, seconds: 5)]
        )

        XCTAssertTrue(resolution.roomSpeakers.isEmpty)
        XCTAssertEqual(Set(resolution.segments.map(\.speakerId)), ["microphone"])
    }

    /// The diarizer splitting one person in two must not create a stranger.
    func testOverSplitOwnerFoldsBackIntoTheOwner() {
        let resolution = resolve(
            microphone: [voice("S1", 0, seconds: 60), voice("S2", 0, degrees: 20, seconds: 30)]
        )

        XCTAssertTrue(resolution.roomSpeakers.isEmpty)
        XCTAssertEqual(Set(resolution.segments.map(\.speakerId)), ["microphone"])
    }

    func testSegmentsShiftOntoTheMeetingTimeline() {
        let resolution = resolve(microphone: [voice("S1", 0, seconds: 30)], startOffsetMs: 250)

        XCTAssertEqual(resolution.segments.first?.startMs, 250)
        XCTAssertEqual(resolution.segments.first?.endMs, 1_150)
    }

    // MARK: Finalizer

    func testMicrophoneLabelNamesTheOwner() {
        let finalized = MeetingTranscriptFinalizer.finalize(
            sourceTranscripts: [source(.microphone, ["hello"], startMs: 0)],
            microphoneLabel: "Liam"
        )

        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "microphone", label: "Liam")])
    }

    func testWithoutAttributionTheMicrophoneStaysOneSpeakerNamedMe() {
        let finalized = MeetingTranscriptFinalizer.finalize(
            sourceTranscripts: [source(.microphone, ["hello", "there"], startMs: 0)]
        )

        XCTAssertEqual(finalized.words.map(\.speakerId), ["microphone", "microphone"])
        XCTAssertEqual(finalized.speakers, [SpeakerInfo(id: "microphone", label: "Me")])
    }

    func testMicrophoneWordsFollowRoomVoicesAndEcho() {
        let finalized = MeetingTranscriptFinalizer.finalize(
            sourceTranscripts: [source(.microphone, ["mine", "theirs", "echo", "unclaimed"], startMs: 0)],
            systemDiarization: .init(
                speakers: [SpeakerInfo(id: "system:S1", label: "Others 1")], segments: []
            ),
            microphoneAttribution: .init(
                segments: [
                    SpeakerSegment(speakerId: "microphone", startMs: 0, endMs: 900),
                    SpeakerSegment(speakerId: "microphone:S2", startMs: 1_000, endMs: 1_900),
                    SpeakerSegment(speakerId: "system:S1", startMs: 2_000, endMs: 2_900),
                ],
                roomSpeakers: [SpeakerInfo(id: "microphone:S2", label: "Room 1")]
            ),
            microphoneLabel: "Liam"
        )

        XCTAssertEqual(
            finalized.words.map(\.speakerId),
            ["microphone", "microphone:S2", "system:S1", "microphone"]
        )
        XCTAssertEqual(
            finalized.speakers,
            [
                SpeakerInfo(id: "microphone", label: "Liam"),
                SpeakerInfo(id: "microphone:S2", label: "Room 1"),
                SpeakerInfo(id: "system:S1", label: "Others 1"),
            ])
    }

    func testRoomLabelsCountAsAutomatic() {
        XCTAssertTrue(SpeakerInfo(id: "microphone:S2", label: "Room 1").carriesAutomaticLabel)
        XCTAssertFalse(SpeakerInfo(id: "microphone:S2", label: "Dana").carriesAutomaticLabel)
    }

    // MARK: Preferences

    func testMicrophoneLabelPreference() throws {
        let suite = "MeetingMicrophoneSpeakerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(UserDefaultsAppRuntimePreferences.meetingMicrophoneLabel(defaults: defaults), "Me")
        defaults.set("   ", forKey: UserDefaultsAppRuntimePreferences.meetingOwnerNameKey)
        XCTAssertEqual(UserDefaultsAppRuntimePreferences.meetingMicrophoneLabel(defaults: defaults), "Me")
        defaults.set(" Liam Wynne ", forKey: UserDefaultsAppRuntimePreferences.meetingOwnerNameKey)
        XCTAssertEqual(UserDefaultsAppRuntimePreferences.meetingMicrophoneLabel(defaults: defaults), "Liam Wynne")

        let id = UUID()
        UserDefaultsAppRuntimePreferences.setOwnerVoiceProfileID(id, defaults: defaults)
        XCTAssertEqual(UserDefaultsAppRuntimePreferences.ownerVoiceProfileID(defaults: defaults), id)
        UserDefaultsAppRuntimePreferences.setOwnerVoiceProfileID(nil, defaults: defaults)
        XCTAssertNil(UserDefaultsAppRuntimePreferences.ownerVoiceProfileID(defaults: defaults))
    }

    // MARK: Fixtures

    private struct Voice {
        let id: String
        let embedding: SpeakerEmbedding
        let seconds: Double
    }

    private func embedding(_ axis: Int, degrees: Double = 0) -> SpeakerEmbedding {
        let radians = degrees * Double.pi / 180
        var values = [Float](repeating: 0, count: SpeakerEmbedding.dimension)
        values[axis] = Float(cos(radians))
        values[SpeakerEmbedding.dimension - 1 - axis] = Float(sin(radians))
        guard let embedding = SpeakerEmbedding(rawVector: values, identity: identity) else {
            preconditionFailure("fixture vector must be valid")
        }
        return embedding
    }

    private func voice(_ id: String, _ axis: Int, degrees: Double = 0, seconds: Double) -> Voice {
        Voice(id: id, embedding: embedding(axis, degrees: degrees), seconds: seconds)
    }

    private func profile(voice axis: Int) -> SpeakerProfileCandidate {
        SpeakerProfileCandidate(
            profileId: UUID(), displayName: "Owner",
            references: [.init(embedding: embedding(axis), captureDomain: .microphone)]
        )
    }

    /// One segment per voice, 1 s apart, so tests can find a voice's segment by
    /// its start time.
    private func diarization(_ voices: [Voice]) -> MacParakeetDiarizationResult {
        MacParakeetDiarizationResult(
            segments: voices.enumerated().map { index, voice in
                SpeakerSegment(speakerId: voice.id, startMs: index * 1_000, endMs: index * 1_000 + 900)
            },
            speakerCount: voices.count,
            speakers: voices.map { SpeakerInfo(id: $0.id, label: $0.id) },
            speakerEmbeddings: Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.embedding) }),
            speechMsBySpeaker: Dictionary(uniqueKeysWithValues: voices.map { ($0.id, Int($0.seconds * 1000)) })
        )
    }

    private func resolve(
        microphone: [Voice],
        system: [Voice] = [],
        owner: SpeakerProfileCandidate? = nil,
        startOffsetMs: Int = 0
    ) -> MeetingMicrophoneSpeakerResolver.Resolution {
        let systemDiarization: MeetingTranscriptFinalizer.SystemDiarization? = system.isEmpty
            ? nil
            : .init(
                speakers: system.map { SpeakerInfo(id: "system:\($0.id)", label: "Others") },
                segments: [],
                speakerEmbeddings: Dictionary(
                    uniqueKeysWithValues: system.map { ("system:\($0.id)", $0.embedding) }
                ),
                speechMsBySpeaker: Dictionary(
                    uniqueKeysWithValues: system.map { ("system:\($0.id)", Int($0.seconds * 1000)) }
                )
            )
        return MeetingMicrophoneSpeakerResolver.resolve(
            microphone: diarization(microphone),
            startOffsetMs: startOffsetMs,
            systemDiarization: systemDiarization,
            ownerVoice: owner
        )
    }

    /// Words one second apart, each 0.5 s long.
    private func source(
        _ audioSource: AudioSource, _ words: [String], startMs: Int
    ) -> MeetingTranscriptFinalizer.SourceTranscript {
        let timed = words.enumerated().map { index, word in
            TimestampedWord(
                word: word, startMs: startMs + index * 1_000, endMs: startMs + index * 1_000 + 500,
                confidence: 0.9
            )
        }
        return .init(
            source: audioSource,
            result: STTResult(text: words.joined(separator: " "), words: timed),
            startOffsetMs: 0
        )
    }
}
