> Sonnet 5 review, via Claude Code. Retention and ordinary transaction-failure caveats below were subsequently resolved in report.md. This review is source analysis, not production test evidence.

## Review: `docs/research/2026-09-11-issue-895-meeting-split/report.md`

**Verification method:** Checked `origin/main` at `aaf3dc261536e5fc5158c4b1ca714bd3f4cece19` (confirmed via `git rev-parse origin/main`, matching the report's pinned SHA) against `audio-range-results.json` and 7 of the report's code citations via `git show <sha>:<path>`.

**Citations verified exact:**
- `MeetingArtifactStore.swift:458` — `sessionFolderURL(for:)` starts exactly at line 458, and `removeOwnedMeetingAudio` (in `TranscriptionAssetCleanup.swift`) resolves that same folder and deletes it wholesale — confirms "audio removal operates on a meeting folder" and the independent-directory recommendation.
- `MeetingRecordingMetadata.swift` — `Track.startOffsetMs`, `writtenFrameCount`, `timelineFrameCount(Int64?)` exist as described; `timelineFrameCount` is explicitly documented as including recovery padding, supporting the "aggregate counters can't locate per-part coverage" claim.
- `SpeakerAttributionResolver.swift` — `EffectiveSpeakerAttribution` has `fingerprint`, `correctionRevision`, `provenanceByWord: [SpeakerWordProvenance]` (with `audioSource`), and `unresolvedCorrections`. `SpeakerAssignment` (`SpeakerCorrection.swift`) has an explicit `.unassigned` case. This substantiates the "snapshot effective attribution + explicit unassigned spans + separate automatic source provenance" claims precisely.
- `TranscriptionRepository.swift` — `fetchMeetingAudioRetentionCandidates(createdAtOrBefore:)` filters strictly on `createdAt <= cutoff`, confirming the sweeper-by-`createdAt` claim.
- `DatabaseManager.swift` — `speaker_profiles`/exemplars migration (v0.39) exists as cited, consistent with the voiceprint feature-off caveats.
- `spec/contracts/meeting-recovery-retention.md` — `recording.lock`, `.finalization-ownership.lock` advisory mutex, and `finalizationLeaseId` are real, existing mechanisms scoped to single-recording finalization, not multi-row cross-meeting commits — this correctly supports the report's claim that they are a *precedent*, not a reusable lock for this feature.

I found no misrepresented API, no fabricated field, and no citation pointing at the wrong construct.

**Internal-consistency checks:** The chronology example (36:20 + 35:50 + 35:50 = 1:48:00) is arithmetically correct. The intersection formula (`a=max(s,o)`, `b=min(e,o+d)`, child offset `a-s`) correctly preserves a late-starting track's lateness inside the child rather than zeroing it. The `audio-range-results.json` durations (2.137/3.282/2.581s, summing to 8.000s) match the report's "Final observed result" numbers exactly, and `sourceUnchanged: true`/matching SHA-256 support the "original media untouched" claim. The storage-doubling math (~173 MB/hr per full copy, ~346 MB/hr for original+parts) is consistent with covering the same total duration once more, not once per part.

## Caveats (not blocking)

1. **Retention-inheritance risk is under-resolved, not just under-warned.** Keeping the parent's `createdAt` on children is reasonable for avoiding a silently extended lifetime, but combined with the confirmed `createdAt <= cutoff` sweep predicate, a parent recording that is *already past* its retention cutoff (audio simply hasn't been swept yet) would produce children whose brand-new audio is *already* eligible for deletion on the very next sweep — potentially within hours of the split completing. The report calls this "a warning," but a warning alone doesn't prevent a user from doing real work (renaming, reviewing) on a child whose audio disappears almost immediately. This deserves an explicit decision (e.g., a grace-period exemption for split-derived audio) before implementation, not just a UI notice.

2. **DB-transaction failure path is asymmetric with the crash path.** The pipeline states a crash before commit leaves recoverable staged files, and a crash after commit is recognized by operation ID — but it doesn't equally spell out ordinary (non-crash) transaction failure after folders are installed (e.g., a constraint violation on the last child row). This is likely covered implicitly by "settle operation journal" but is worth making explicit in the eventual contract.

3. **The `createdAt`/date-grouping choice and the "computed relationship" surfacing are both first-release simplifications the report flags as such** — reasonable to defer, but they should be treated as committed follow-up work, not optional polish, since users will notice date-sorted libraries showing children dated identically to a much-earlier parent.

4. Feasibility numbers are honestly scoped (8-second mono synthetic fixture, no dual-source/long-file/crash testing) and the report repeatedly warns against extrapolating them — this is correctly hedged, not a defect.

## Verdict

**Coherent.** Every code-grounded claim I checked (7 citations across models, resolver, retention query, artifact/cleanup, and the recovery contract) matched current `origin/main` exactly, including two exact line numbers. The eligibility table, atomicity design, and speaker-provenance handling are internally consistent and appropriately conservative (no STT rerun, no silent word-crossing cuts, no copied undo chains, no voice-profile side effects). The retention-inheritance interaction (caveat 1) is the one place where the report's own evidence implies a sharper practical risk than the text conveys, and should be tightened before this becomes an implementation contract. No blocking factual corrections are needed.
