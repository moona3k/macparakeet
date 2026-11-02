import Foundation

/// Decides what each diarized microphone-track voice is.
///
/// A microphone hears more than its owner. On speakers, the far end of the call
/// plays into the room and comes back as echo that cancellation can miss; in a
/// meeting room, colleagues share the microphone. Without this, all of it is
/// labelled as the owner (`Me`). Each microphone cluster is one of:
///
/// - **echo** — its voice matches a diarized system-audio cluster, so its words
///   belong to that participant, not to the owner;
/// - **the owner** — the voice that matches the owner's saved voice, or, with no
///   saved voice or no match, the remaining voice with the most speech. Its
///   words keep the `microphone` id;
/// - **a room voice** — any other voice with enough speech to be a person rather
///   than a fragment, which becomes its own `microphone:Sn` speaker.
///
/// Short fragments and a voice that sits as close to the owner as a profile
/// match would (the diarizer over-splitting one person) fold into the owner, so
/// a headset meeting keeps exactly the transcript it had before.
enum MeetingMicrophoneSpeakerResolver {
    static let roomLabelPrefix = "Room "

    struct Resolution: Sendable {
        /// Final-id segments, shifted onto the meeting timeline. The owner's
        /// clusters carry `microphone`, echo carries the system cluster it
        /// matched, room voices carry `microphone:Sn`.
        let segments: [SpeakerSegment]
        let roomSpeakers: [SpeakerInfo]
        /// The owner's voice, keyed `microphone`, for retention and recognition.
        let ownerObservation: SpeakerClusterObservation?
        let roomObservations: [SpeakerClusterObservation]
        /// Raw microphone cluster id → system cluster id it was heard as echo of.
        let echoTargets: [String: String]
        /// Distance from the owner's cluster to the owner's saved voice.
        let ownerDistance: Double?
    }

    static func resolve(
        microphone diarization: MacParakeetDiarizationResult,
        startOffsetMs: Int,
        systemDiarization: MeetingTranscriptFinalizer.SystemDiarization?,
        ownerVoice: SpeakerProfileCandidate?,
        policy: SpeakerMatchPolicy = .v1
    ) -> Resolution {
        let clusterIDs = diarization.speakers.map(\.id)
        func observation(_ id: String, as speakerId: String) -> SpeakerClusterObservation? {
            guard let embedding = diarization.speakerEmbeddings[id] else { return nil }
            return SpeakerClusterObservation(
                speakerId: speakerId,
                embedding: embedding,
                speechSeconds: diarization.speechSeconds(forSpeaker: id),
                captureDomain: .microphone
            )
        }

        // Echo first: a far-end voice can out-talk the owner on a loud speaker,
        // and must never be chosen as them.
        var echoTargets: [String: String] = [:]
        if let systemDiarization {
            let systemVoices: [(id: String, embedding: SpeakerEmbedding)] = systemDiarization.speakers.compactMap {
                guard let embedding = systemDiarization.speakerEmbeddings[$0.id],
                    Double(systemDiarization.speechMsBySpeaker[$0.id] ?? 0) / 1000
                        >= policy.minSpeechSecondsToMatch
                else { return nil }
                return ($0.id, embedding)
            }
            for id in clusterIDs {
                guard let embedding = diarization.speakerEmbeddings[id] else { continue }
                let nearest = systemVoices.compactMap { voice in
                    embedding.cosineDistance(to: voice.embedding).map { (voice.id, $0) }
                }.min { $0.1 < $1.1 }
                if let nearest, nearest.1 <= policy.tau {
                    echoTargets[id] = nearest.0
                }
            }
        }

        let voiced = clusterIDs.filter { echoTargets[$0] == nil }

        // The owner: the saved voice decides when it matches; otherwise the
        // most speech, which is the owner in every setup but a room where a
        // colleague out-talks them — the case enrolling a voice is for.
        func ownerMatch(_ id: String) -> SpeakerVoiceprintMatcher.ReferenceMatch? {
            guard let ownerVoice, let candidate = observation(id, as: id) else { return nil }
            return SpeakerVoiceprintMatcher.bestReference(from: candidate, to: ownerVoice, policy: policy)
        }
        let recognized = voiced
            .compactMap { id in ownerMatch(id).map { (id: id, match: $0) } }
            .filter { $0.match.distance <= SpeakerVoiceprintMatcher.effectiveTau(for: $0.match, policy: policy) }
            .min { $0.match.distance < $1.match.distance }
        let ownerID = recognized?.id ?? voiced.max {
            diarization.speechSeconds(forSpeaker: $0) < diarization.speechSeconds(forSpeaker: $1)
        }
        let ownerDistance = ownerID.flatMap { ownerMatch($0)?.distance }

        // Room voices: enough speech to enroll, and not the owner over-split.
        let ownerEmbedding = ownerID.flatMap { diarization.speakerEmbeddings[$0] }
        var roomIDs: [String] = []
        for id in voiced where id != ownerID {
            guard diarization.speechSeconds(forSpeaker: id) >= policy.minSpeechSecondsToEnroll,
                let embedding = diarization.speakerEmbeddings[id]
            else { continue }
            if let ownerEmbedding, let distance = embedding.cosineDistance(to: ownerEmbedding),
                distance <= policy.tau
            {
                continue
            }
            roomIDs.append(id)
        }

        let microphoneID = AudioSource.microphone.rawValue
        let roomFinalIDs = Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, "\(microphoneID):\($0)") })
        let roomSpeakers = roomIDs.enumerated().map { index, id in
            SpeakerInfo(id: roomFinalIDs[id]!, label: "\(roomLabelPrefix)\(index + 1)")
        }

        let segments = diarization.segments.map { segment in
            let finalID = echoTargets[segment.speakerId]
                ?? roomFinalIDs[segment.speakerId]
                ?? microphoneID
            return SpeakerSegment(
                speakerId: finalID,
                startMs: segment.startMs + startOffsetMs,
                endMs: segment.endMs + startOffsetMs
            )
        }

        return Resolution(
            segments: segments,
            roomSpeakers: roomSpeakers,
            ownerObservation: ownerID.flatMap { observation($0, as: microphoneID) },
            roomObservations: roomIDs.compactMap { observation($0, as: roomFinalIDs[$0]!) },
            echoTargets: echoTargets,
            ownerDistance: ownerDistance
        )
    }
}
