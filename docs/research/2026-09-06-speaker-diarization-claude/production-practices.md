# Production speaker attribution practices (web research, observed 2026-09-06)

Scope: how shipping meeting and transcription products make speaker attribution reliable, based
only on official docs, API references, and vendor engineering posts observed on 2026-09-06.
Companion evidence excerpts: `evidence/production-*.md`. Local baseline for MacParakeet comes
from `spec/adr/010-speaker-diarization.md` and the 2026-09-06 peer review
(`../2026-09-06-oss-review-astra/macparakeet-baseline.md`), read but not modified.

## 1. Verdict

No production product relies on a single-pass, blind diarizer. Every reliable system combines
at least two of: (a) an identity source that is not acoustic (per-participant streams, channel,
calendar or platform display names), (b) a speaker-count prior supplied by the caller, (c)
word-level assignment of ASR output to an overlap-free ("exclusive") diarization, (d) per-segment
confidence that drives a correction UI, and (e) an explicit, revocable enrollment path for
cross-meeting identity.

MacParakeet already holds the strongest non-acoustic signal a local recorder can have: separate
microphone and system-audio sources, and it already diarizes asynchronously on retained audio.
The products that publish results comparable to "perfect separation" get there by treating
channel identity as ground truth and diarizing only inside each channel. The gap between
MacParakeet and the best-documented practice is therefore not mainly the model. It is the
surrounding contract: speaker-count priors from the user, word-level assignment against an
exclusive timeline, confidence-driven review, propagate-on-rename corrections, and an opt-in
voiceprint store that MacParakeet can hold locally, unlike the cloud vendors that must delete
outputs within 24 hours.

## 2. Findings

### 2.1 Pattern matrix (documented mechanisms only)

Legend: Y = documented and shipped; N = documented as absent; U = unknown or undocumented;
partial = documented with a restriction noted in the cell.

| Mechanism | pyannoteAI | AssemblyAI | Deepgram | Soniox | Granola | Zoom | Teams | Google Meet | Otter | Fireflies / Fathom |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Channel or stream identity as primary label | N (single mix input) | Y `multichannel`, labels per channel, "more accurate" | Y `multichannel`, 20 channels | U | Y Me/Them = mic vs system audio | Y per-participant local audio files; per-stream names in cloud transcript | Y per-stream identity; room feed attributed "to the space" without recognition | Y per-participant (mechanism not documented officially) | partial (platform display names when learning disabled) | Fathom: in-room audio all attributed to the Fathom user |
| Embedding diarization inside a channel | Y | Y (combined with multichannel, labels "1A", "2B") | Y (speaker numbering resets per channel) | Y token-level | U (in-person mobile only, internals undocumented) | Y in Zoom Rooms only | Y in rooms only | U | Y | Fireflies Y; Fathom N in-room |
| Caller-supplied speaker count | Y `numSpeakers`, `minSpeakers`, `maxSpeakers`; "better overall diarization performance" | Y `speakers_expected` (exact, "only when certain"), `min/max_speakers_expected` (hard limits; extra speakers merged) | N (no parameter documented) | N (hard cap 15) | N | N | N | N | N | N |
| Overlap handling | Y `exclusive` = "without overlapping speech", "most likely to be transcribed" speaker kept | documented as accuracy-reducing only | U | U | documented as a limitation only | U | U | U | best practice: "Avoid speaking over one another" | U |
| Word-level speaker labels | Y via orchestrated transcription; merge tutorial for BYO ASR | Y per word and per utterance | Y per word plus `speaker_confidence` | Y per token | N (turns only) | phrase-level VTT | U | U | paragraph-level | Fathom: item-level with timestamp |
| ASR to diarization alignment rule | Y: max temporal overlap per segment/word, `fill_nearest`, else `UNKNOWN` (WhisperX logic) | U (internal) | U (internal) | U (internal) | U | U | U | U | U | U |
| Provisional then final labels | Y: Live-1 streaming vs Precision-2 batch | Y: streaming labels per word; batch is separate | Y: streaming has no confidence; v2 batch only | Y: "temporary speaker switches that stabilize"; async "significantly higher" accuracy | U | U | U | U | U | Fireflies: live generic labels, names after call (third-party summary only) |
| Per-segment confidence | Y 0-100, 20 ms resolution, turn-level; "human in the loop correction" | N | Y `speaker_confidence` per word, batch only | N | N | N | N | N | N | N |
| Rename applies to whole speaker | n/a (API) | n/a | n/a | n/a | in notes or via chat; persistence undocumented | phrase-level edit only | U | U | Y all paragraphs and all conversations | Fireflies: "Apply to all Speaker X" in transcript |
| Merge / split / undo in UI | n/a | n/a | n/a | n/a | U | N | U | U | Retag, Untag, Rematch | U |
| Corrections train future identity | n/a | N ("does not offer speaker enrollment") | N | U | U | N (Rooms enrollment is explicit) | N (explicit enrollment) | U | Y ("tag once", learns "from a few tagged paragraphs") | Fireflies N by policy |
| Voiceprint enrollment | Y: 30 s max, single speaker, caller stores; threshold 0-100; exclusive match | N (cookbook: third-party embeddings + vector DB) | N | N (not documented) | N | Y Zoom Rooms: read text aloud; consent; cloud storage; deletable | Y: opt-in, passive over "a couple of meetings" or manual; tenant store; delete on unenroll; 1-year expiry | U | Y implicit via tagging; enterprise "Disable Speaker Learning" | N |
| Name inference from context (LLM) | N | Y Speech Understanding: names or roles, "no voice enrollment needed" | N | N | Y ("contextual clues") | N | N | N | N | Fireflies: calendar and conversation clues (not on a Fireflies page) |
| Published accuracy claim | 28% rel. DER gain vs Community-1 on 259 files, 67 h, 9.3% overlap, no oracle count; collar unknown | DER 29.1% to 20.4% on 205 h (AMI, DIPCO, VoxConverse); cpWER 30.17 internal; conditions partial | CER median down ~80%, 3.3x human preference (158 votes); no DER, datasets unknown | none | none | none | none | none | none | none |

### 2.2 Per-exemplar notes

**pyannoteAI (docs.pyannote.ai).** The API is the clearest published statement of the batch
pattern. Speaker count is a first-class prior; the docs say setting `numSpeakers` "typically
results in better overall diarization performance" and recommend "begin with automatic
detection ... then refine with constraints in subsequent processing". The `exclusive` output
removes overlap so that "each segment contains exactly one speaker, which makes it easier to
align with STT/ASR results". Confidence is emitted at 20 ms resolution and per turn, and the
stated purpose is to "Focus human review time on the most uncertain segments". Voiceprints are
built from at most 30 s of single-speaker audio, matched with a 0-100 threshold ("50-70" for
strict), with `exclusive` matching preventing two diarized speakers from mapping to one
voiceprint. The vendor deletes outputs after 24 hours, so the caller owns the voiceprint store.
Precision-2 is claimed 28% more accurate than Community-1 on a 10-domain, 259-file, 67-hour
set with 9.3% overlap and no oracle speaker count. Collar and overlap scoring are not stated on
the benchmark page. Its internal "correct number of speakers on 70% of files" claim is on a
250-file, 2-10 speaker set, up from about 50% for Precision-1. All from evidence/production-pyannoteai.md.

**AssemblyAI.** Documents both mechanisms side by side. Multichannel is "more accurate since
each speaker's audio is processed independently", and the meeting-notetaker guide calls
per-participant recording "Perfect speaker separation — No diarization errors" (that phrase is a
guide claim, not a measurement). Diarization can run inside each channel, and `speaker_options`
then apply per channel. Speaker count has three knobs: exact (`speakers_expected`, "only when
certain"), hard minimum, and hard maximum ("additional speakers are merged into existing
labels"). Guidance: set the maximum "a bit higher than expected; too high can cause
over-splitting". The FAQ describes the pipeline as word-timed chunks, embeddings, and
clustering, with about 30 s needed per distinct speaker; brief interjectors are folded into the
most similar cluster. Name mapping is done by a Speech Understanding step from conversation
content and caller-supplied names or roles, with "no voice enrollment needed"; AssemblyAI
explicitly "does not offer speaker enrollment", and cross-file identity is a cookbook using a
third-party embedding model and a vector database. Accuracy: the 2025 speaker-tracking post
reports DER 29.1% to 20.4% on 205+ hours including AMI, DIPCO, VoxConverse, with a table by
noise and segment length; collar, overlap scoring, and oracle count are not stated. The July
2026 Universal-3.5 Pro cpWER of 30.17 is on an internal benchmark. evidence/production-assemblyai.md.

**Deepgram.** Word-level `speaker` plus `speaker_confidence` on batch requests only; streaming
gets labels without confidence. No speaker-count parameter is documented. Multichannel and
diarization compose, with speaker numbering reset per channel. Batch diarization v2 (May 2026)
is a new embedding model plus segmentation and clustering, evaluated by Confusion Error Rate
and a 158-vote human preference (63.3% v2, 19.0% v1). No DER, datasets, or collar are
published. evidence/production-deepgram-soniox.md.

**Soniox.** Token-level speaker labels, up to 15 speakers, no caller-supplied count. The docs
are unusually candid that real-time labels show "temporary speaker switches that stabilize as
more context is available" and that forced finalization "reduces diarization accuracy"; async is
recommended for "significantly higher diarization accuracy because the model has access to the
full audio context". No speaker identification or enrollment documentation was found; two
candidate URLs returned 404. evidence/production-deepgram-soniox.md.

**Granola.** Default labels are "Me" and "Them", "corresponding to your microphone input and
system audio". Real names appear only where the meeting platform exposes display names (Google
Meet via the browser extension; Zoom on macOS). Otherwise names are inferred by an LLM "from
contextual clues in the transcript", and users correct them in notes or through chat. Granola
"does not record or save audio", so it cannot re-diarize after the fact, which explains why it
leans on platform identity and text inference. Limitations are stated: no per-person split of a
shared device, overlap not handled, background audio unattributed. Mobile in-person
diarization exists but internals are undocumented. evidence/production-granola-fireflies-fathom.md.

**Zoom, Teams, Google Meet.** These platforms own per-participant streams, so remote attribution
is identity-based rather than acoustic. Zoom local recording can write one audio file per
participant named after the participant; cloud transcripts are phrase-level VTT with an
"Unknown Speaker" edit affordance. In-room identification requires explicit voice enrollment:
Zoom Rooms smart name tags for voice (read a passage aloud, consent, cloud-stored reference
audio, deletable, "1-16 in-room participants"), and Teams voice profiles (opt-in, passive
enrollment over "a couple of meetings" or manual, tenant store, deleted on unenroll, one-year
expiry, admin policy "Attribute" shows enrolled names and "Speaker" for others, "Distinguish"
shows only numbered speakers). Without recognition, Teams attributes the room feed "to the
space (for example, Conference Room 1)". Google Meet's official page documents only what is
included and which languages; the attribution mechanism is not documented. A local recorder
cannot obtain any of these per-participant streams. evidence/production-platforms-otter.md.

**Otter.** The clearest documented correction-trains-identity loop: "You only need to tag a
Speaker # once", tagging "will automatically tag all other associated Speaker #s in the
conversation", rename propagates "across all conversations", and "Rematch" re-runs matching on
old conversations with "present-day speaker data". Best practices tell users to keep display
names consistent and to keep each paragraph single-speaker because mixed paragraphs "can reduce
future speaker identification accuracy". Enterprises can disable learning, after which labels
"rely on participant names provided by your video conferencing platform". Direct fetches of
help.otter.ai returned 403, so these are official-article snippets via search.

**Fireflies and Fathom.** Fireflies renames offer "Apply to current speaker" or "Apply to all
'Speaker X'", and its privacy policy says providers "do not use voice data to identify or
authenticate individuals". Fathom exposes `matched_calendar_invitee_email` per speaker and states
plainly that in-room "Fathom cannot distinguish between multiple speakers" and "All audio will be
attributed to the Fathom user's name".

**Google Pixel Recorder (bonus local-only exemplar).** On-device speaker labels, voice models
"deleted within a few minutes after labeling", and a paragraph-level rename that does not
propagate, which is the anti-pattern users complain about elsewhere.

### 2.3 Cross-cutting topics

**Channel identity vs embedding identity.** Every vendor that supports both ranks channel
identity above clustering (AssemblyAI: "more accurate"; Deepgram: run diarization inside each
channel; Teams and Zoom: per-stream identity is the default and acoustic recognition is the
special case for rooms). No vendor documents mixing channels and then re-separating them.

**Speaker-count priors.** pyannoteAI and AssemblyAI expose exact and bounded counts and say the
prior improves results; both warn that an exact count is only safe when certain, and AssemblyAI
warns that a hard maximum merges surplus speakers. Deepgram and Soniox expose none. Platforms
derive the count from the participant list rather than asking.

**Overlap.** Only pyannoteAI documents an explicit policy: exclusive output keeps the speaker
"most likely to be transcribed". Everyone else either states overlap hurts or says nothing.
No product documents attributing one ASR word to two speakers.

**Word vs segment timestamps and drift.** Deepgram, Soniox, and AssemblyAI label at the word or
token level. pyannoteAI publishes the alignment rule (maximum overlap, nearest-midpoint fallback,
UNKNOWN otherwise) and pairs it with exclusive diarization to make the rule well-defined. No
vendor documents a correction for systematic ASR versus diarization timestamp offset.

**Provisional vs final.** Soniox and pyannoteAI document that streaming labels are provisional
and that batch on full context is more accurate. Deepgram withholds confidence and v2 from
streaming. Fireflies (per third-party description) shows generic live labels and fills names
after the call.

**Correction UX.** Best documented: Otter (tag once applies to all, rename across conversations,
rematch, untag, disable learning) and Fireflies (apply to one or all). Weakest: Zoom cloud
transcript and Pixel Recorder (per-phrase or per-paragraph edits). Whether corrections feed
future identification is a deliberate product choice: Otter yes; AssemblyAI, Fireflies, Teams,
and Zoom no (identity comes from explicit enrollment or platform metadata only).

**Enrollment, consent, privacy.** Three published models: caller-owned voiceprints with
vendor-side 24-hour deletion (pyannoteAI); explicit, revocable, tenant-stored profiles with
export by the user only and automatic expiry (Teams, Zoom Rooms); implicit learning from
corrections with an admin kill switch (Otter). Fireflies positions "no biometric
identification" as a feature. Pixel deletes voice models minutes after labeling.

**Accuracy claims.** All are vendor-reported. pyannoteAI gives the most complete conditions
(files, hours, overlap share, no oracle count) but omits collar. AssemblyAI names datasets but
not collar or overlap scoring. Deepgram gives relative CER and preference votes only. No
platform (Zoom, Teams, Meet, Granola, Otter) publishes any attribution accuracy.

## 3. Implications for MacParakeet

MacParakeet's current state per ADR-010: FluidAudio offline pipeline (Community-1 segmentation,
WeSpeaker embeddings, VBx clustering), meetings diarize only the isolated system-audio track,
microphone words are source-labeled "Me", exclusive output trims overlaps (overlap words can get
a nil speaker), no cross-file identity, and speaker rename updates a mapping table. That is
structurally the same shape the cloud vendors recommend. The gaps are in the contract around
the model.

### 3.1 Five strongest patterns for MacParakeet's situation

1. **Treat channel identity as ground truth and diarize only within the remote channel.**
   This is exactly AssemblyAI's "multichannel plus speaker labels" and Deepgram's per-channel
   diarization, and it is what MacParakeet already does with "Me" on the mic track. Keep it, and
   extend it: never let a clustering pass reassign a mic-track word to a remote speaker, and use
   the cleaned mic track (ADR-028) to avoid echo of remote voices being clustered as a new
   speaker on the system track. Causal path: the documented accuracy advantage comes from
   removing speaker confusion between channels entirely, not from a better embedding.

2. **Ask for, or infer, a speaker-count prior and pass it as bounds, not an exact count.**
   pyannoteAI and AssemblyAI both document that a count prior improves clustering, and both warn
   that an exact count is dangerous when wrong. For meetings the count is the number of remote
   participants, which the user usually knows. A "How many people were on the call?" prompt at
   finalization (or a calendar attendee count when available, minus the user) mapped to
   `minSpeakers = max(1, n-1)`, `maxSpeakers = n+1` mirrors AssemblyAI's "a bit higher than
   expected" guidance. Since diarization runs after the meeting, the prior can also be applied in a
   second pass after an automatic first pass, which is pyannoteAI's stated best practice.

3. **Assign ASR words to speakers with the published overlap-maximum rule against an exclusive
   timeline, and give nil-speaker words a documented fallback.** pyannoteAI's merge tutorial and
   WhisperX's `assign_word_speakers` are the only publicly specified alignment rules, and they
   pair exclusive diarization with maximum-overlap assignment plus nearest-midpoint fill.
   MacParakeet already has exclusive output; ADR-010 notes overlap words may be unlabeled. Adopting
   `fill_nearest` semantics and exposing the assignment as a separate, testable step from
   clustering makes drift and boundary errors auditable.

4. **Emit per-turn confidence and use it to drive review, not just display.** pyannoteAI's
   turn-level confidence and Deepgram's per-word `speaker_confidence` exist for one reason:
   "Focus human review time on the most uncertain segments". MacParakeet can compute a cheap
   proxy from cluster margin (distance to the assigned centroid versus the next-best centroid) and
   from turn duration, and surface only low-confidence turns for confirmation. This turns the
   user's correction budget into the accuracy lever that every vendor without enrollment relies
   on.

5. **Make corrections propagate, and make cross-meeting identity an explicit local opt-in.**
   Otter's "tag once, applies to all Speaker #s, rename across conversations, Rematch old
   meetings" is the documented gold standard for correction UX. Fireflies' "apply to one or all"
   is the minimum. Because MacParakeet retains audio and is local-first, it can hold the
   voiceprint store that pyannoteAI forces callers to keep, with Teams-style controls: opt-in per
   person, delete on demand, expiry, and a "Distinguish only" mode that never names anyone.
   Enrollment should come from confirmed turns (Otter's "a few tagged paragraphs", pyannoteAI's
   under-30-second single-speaker clips) rather than a separate enrollment ceremony.

### 3.2 Anti-patterns to avoid

- **Mixing mic and system audio before diarization.** No vendor documents this; every one that
  can separate channels does so. It throws away MacParakeet's best signal.
- **Forcing an exact speaker count.** AssemblyAI merges surplus speakers into existing labels
  and warns to use exact counts only when certain. Use bounds.
- **Per-paragraph renames that do not propagate.** Pixel Recorder and Zoom cloud transcripts
  document this behavior; Otter and Fireflies document the opposite. Users experience the
  former as broken.
- **Silent enrollment.** Teams and Zoom Rooms both require explicit consent and offer deletion
  and export; Otter needed an enterprise kill switch after the fact. Fireflies markets the
  absence of biometrics. A local app has less exposure but should still default to no persistent
  voiceprints and label the feature clearly.
- **Treating live labels as final.** Soniox and pyannoteAI both document that streaming labels
  flip and that full-context batch is materially better. MacParakeet's live preview should not
  show speaker labels that the final pass will contradict.
- **Quoting vendor DER or cpWER as a target without conditions.** Collar, overlap scoring, and
  oracle count are unstated in most claims; MacParakeet's own 2-4% CoreML quantization loss
  (ADR-010) is already a larger effect than some vendor-to-vendor differences.
- **LLM name inference as the identity source.** Granola and AssemblyAI use it, but only as a
  layer over channel or diarization labels, and Granola does so because it has no audio to
  re-diarize. It can suggest names; it should not merge or split speakers.

## 4. Failure scenarios and uncertainty

- **Proprietary internals are unknown** for Granola's mobile diarizer, Otter's matching model,
  Google Meet's attribution mechanism, Deepgram's speaker-count logic, and Soniox's speaker
  identification (undocumented, likely absent). The matrix marks these U.
- **Otter and Zoom local-recording quotes are from search snippets of official articles**, not
  direct fetches (help.otter.ai returned 403; Zoom KB0063640 as fetched did not contain the
  per-participant paragraph). Wording may differ slightly.
- **Vendor accuracy claims are unverified and conditions are incomplete.** pyannoteAI omits
  collar; AssemblyAI omits collar, overlap scoring, and oracle count; Deepgram gives no absolute
  numbers. None of them evaluate the two-channel meeting condition MacParakeet has, so their
  numbers do not bound MacParakeet's achievable error.
- **Channel identity fails when the user is not alone on the mic.** In-room meetings, speaker
  playback without AEC, or a second person at the laptop collapse to "Me", the same failure
  Fathom and Granola document. A within-mic-channel diarization pass would be needed for that
  case, and it should be gated by a user signal (for example an "in-person meeting" toggle),
  not run by default.
- **Speaker-count prompts add friction.** No local competitor documents asking; the vendors that
  benefit are APIs where the caller already knows. If the prompt is skipped, bounds should fall
  back to automatic detection, which pyannoteAI documents as the safe default.
- **Confidence proxies from cluster margin are untested here.** Vendor confidence comes from
  models trained to emit it; a margin-based proxy may be poorly calibrated. It should be
  validated on the retained corpus before it gates any UI.
- **Cross-meeting voiceprints create a new data class.** Teams documents a one-year expiry, user
  export, and admin deletion; pyannoteAI pushes storage to the caller. MacParakeet would need a
  contract document for the store, deletion on speaker delete, and exclusion from exports by
  default. False accepts are not published by any vendor, so thresholds must be tuned locally.
- **Word-level timestamp drift between Parakeet ASR and the diarizer is not addressed by any
  vendor doc.** The maximum-overlap rule tolerates small drift but not systematic offset;
  MacParakeet should measure offset on its own corpus.

## 5. Sources

All observed 2026-09-06 via WebFetch or WebSearch; snippets marked where direct fetch failed.

pyannoteAI
- https://docs.pyannote.ai/ and https://docs.pyannote.ai/llms.txt (index)
- https://docs.pyannote.ai/api-reference/diarize
- https://docs.pyannote.ai/api-reference/identify
- https://docs.pyannote.ai/models
- https://docs.pyannote.ai/features
- https://docs.pyannote.ai/tutorials/speaker-configuration.md
- https://docs.pyannote.ai/tutorials/confidence-scores.md
- https://docs.pyannote.ai/tutorials/diarization-asr-merge.md
- https://docs.pyannote.ai/tutorials/identification-with-voiceprints.md
- https://docs.pyannote.ai/data-retention.md
- https://www.pyannote.ai/benchmark
- https://www.pyannote.ai/blog/precision-2
- https://www.pyannote.ai/blog/how-to-evaluate-speaker-diarization-performance
- https://raw.githubusercontent.com/m-bain/whisperX/main/whisperx/diarize.py (main branch, unpinned)

AssemblyAI
- https://www.assemblyai.com/docs/speech-to-text/speaker-diarization
- https://www.assemblyai.com/docs/pre-recorded-audio/multichannel-transcription
- https://www.assemblyai.com/docs/faq/should-i-use-speaker-labels-or-multi-channel
- https://www.assemblyai.com/docs/faq/how-are-individual-speakers-identified-and-how-does-the-speaker-label-feature-work
- https://www.assemblyai.com/docs/faq/do-you-offer-cross-file-speaker-identification
- https://www.assemblyai.com/docs/meeting-notetaker-best-practices
- https://www.assemblyai.com/docs/speech-understanding/speaker-identification
- https://www.assemblyai.com/blog/speaker-diarization-update
- https://www.assemblyai.com/blog/ai-transcription-with-speaker-identification
- https://www.assemblyai.com/blog/context-influence-automatic-speaker-labeling
- https://www.assemblyai.com/blog/streaming-diarization-major-upgrade
- Universal-3.5 Pro cpWER figures: assemblyai.com blog search snippets (page not fetched directly)

Deepgram
- https://developers.deepgram.com/docs/diarization
- https://developers.deepgram.com/docs/multichannel
- https://developers.deepgram.com/docs/multichannel-vs-diarization
- https://developers.deepgram.com/changelog/2026/5/13
- https://deepgram.com/learn/introducing-batch-diarization-v2
- https://github.com/orgs/deepgram/discussions/1625

Soniox
- https://soniox.com/docs/stt/concepts/speaker-diarization
- Speaker identification: no page found; /docs/stt/concepts/speaker-identification and /docs/stt/speaker-identification returned 404

Granola
- https://docs.granola.ai/help-center/taking-notes/speaker-attribution
- https://docs.granola.ai/help-center/taking-notes/transcription
- https://www.granola.ai/blog/ai-note-taker-in-person-meetings (search snippet)

Zoom
- https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0063640 (local recording; per-participant paragraph not present in fetched text)
- https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0064927 (audio transcription)
- https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0077409 (smart name tags for voice)
- https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0080794 (Voice Recorder)
- Per-participant local audio wording: https://www.techrepublic.com/article/how-to-record-separate-audio-for-each-person-in-a-zoom-call/ and https://help.sonix.ai/en/articles/5520629 (secondary)

Microsoft Teams
- https://learn.microsoft.com/en-us/microsoftteams/rooms/voice-recognition (dated 2026-08-27)
- https://learn.microsoft.com/en-us/microsoftteams/rooms/voice-and-face-recognition (dated 2026-04-16)
- https://support.microsoft.com/en-us/teams/calls-devices/use-microsoft-teams-intelligent-speakers-to-identify-in-room-participants-in-a-meeting-transcription

Google
- https://support.google.com/meet/answer/12849897?hl=en
- https://support.google.com/meet/thread/208156729 (thread body not retrievable)
- https://support.google.com/pixelphone/answer/16269004?hl=en

Otter (official articles; content via search snippets because direct fetch returned 403)
- https://help.otter.ai/hc/en-us/articles/21665587209367-Speaker-Identification-Overview
- https://help.otter.ai/hc/en-us/articles/360048465453-Tagging-speaker-names-in-a-conversation
- https://help.otter.ai/hc/en-us/articles/21665980053655-Rename-a-speaker
- https://help.otter.ai/hc/en-us/articles/21665876084119-Rematch-a-speaker
- https://help.otter.ai/hc/en-us/articles/37817241040535-Best-Practices-to-Maximize-Speaker-Identification
- https://help.otter.ai/hc/en-us/articles/40643231903639-Disable-Speaker-Learning

Fireflies and Fathom
- https://guide.fireflies.ai/articles/4994477228-how-to-edit-speaker-labels-or-names-in-a-transcript
- https://fireflies.ai/privacy-policy (search snippet)
- https://help.fathom.video/en/articles/5500225
- https://developers.fathom.ai/api-reference/recordings/get-transcript

Local (read-only)
- spec/adr/010-speaker-diarization.md (amendments 2026-07-03 and 2026-07-05)
- spec/adr/028-meeting-echo-cancellation.md
- docs/research/2026-09-06-oss-review-astra/macparakeet-baseline.md
