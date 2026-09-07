# Brief: how strong meeting/transcription products make speaker attribution reliable (web research)

Own: docs/research/2026-09-06-speaker-diarization-claude/production-practices.md and evidence/production-*.
Read briefs/shared.md first. Web browsing is required. Observation date 2026-09-06.

Goal: separate the documented mechanisms real products use from marketing, and extract the
narrow patterns that apply to a local-first Mac app that diarizes asynchronously after the
meeting.

Exemplars (5-7, documented mechanisms only): pyannoteAI (precision-2 API docs, "exclusive"
diarization, speaker identification/enrollment), AssemblyAI (speaker labels, speakers_expected,
multichannel), Deepgram (diarize, multichannel), Soniox (speaker diarization + identification),
Granola (how it labels "Me" vs others; it is known to record mic and system audio separately),
Otter/Zoom/Teams/Google Meet (per-participant audio streams and identity from the meeting
platform; note that a local recorder cannot get those streams), Fireflies or Fathom only if
they document something specific.

Cover: channel/source identity vs embedding-based identity; speaker-count priors and how
products let users set them; overlap handling; word vs segment timestamps; provisional vs
final labels; correction UX (rename, apply to all, merge, split, undo) and whether corrections
train future identification; speaker profiles/enrollment and consent/privacy handling;
timing drift between ASR and diarization; any published accuracy claims with their conditions.

Deliver a source-backed pattern matrix, the 5 strongest patterns for MacParakeet's situation,
and anti-patterns to avoid. State explicitly where proprietary internals are unknown.
