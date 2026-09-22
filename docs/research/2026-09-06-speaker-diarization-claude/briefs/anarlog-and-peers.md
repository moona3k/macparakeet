# Brief: Anarlog and open-source peers — how they do speaker attribution

Own: docs/research/2026-09-06-speaker-diarization-claude/anarlog-and-peers.md and evidence/peers-*.
Read briefs/shared.md first.

Goal: explain concretely how Anarlog produces speaker labels today, end to end, and compare with
the other open-source meeting apps in the clones directory (Muesli, Meetily, Minutes, Vibe; the
dictation apps Handy/VoiceInk/OpenWhispr only if they do anything with speakers).

For Anarlog, trace from source (not README claims):
- Which STT providers/models are used locally vs cloud, and which of them return speaker labels.
  Look at crates/ (transcribe-*, listener, voiceprint, db-app), apps/desktop/src (services,
  session, transcript, speaker assignment UI), plugins, and any diarization model download code.
- Whether diarization is a separate local model (which one: pyannote, sortformer, wespeaker,
  3D-Speaker, sherpa-onnx, etc.), a cloud provider feature (Deepgram/AssemblyAI/their own
  cloud), or merely mic-vs-system channel labeling ("You" vs "Others"). Be exact about which
  path a default local-only user actually gets.
- How mic and system audio channels are used for speaker identity (channel = speaker prior?).
- Word/segment timestamps and how speaker labels are merged into the transcript.
- Voiceprint crate: embedding model, exemplar storage, matching thresholds, when it runs.
- Speaker correction UX: rename, apply-to-all, merge/split, undo, persistence across sessions
  (PR #7353 context).
- Anything about overlap, speaker count hints, or post-processing / LLM-based relabeling.
- Git history: when diarization arrived and what changed recently (git log in the clone is fine).
For each peer app, a shorter version of the same: the actual mechanism, model, and whether it
is local. Note Muesli's approach specifically (earlier memory says it has a CLI live-refresh
pattern worth adopting; here focus on speakers only).

End with a comparison matrix (mechanism, model, local/cloud, channel prior used?, word
timestamps?, correction UX, license) and 3-5 narrow lessons for MacParakeet.
