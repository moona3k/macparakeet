# Voice-profile integration review — 2026-09-15

## Decision and scope

Issue [#662](https://github.com/moona3k/macparakeet/issues/662) and contributor
PRs [#1007](https://github.com/moona3k/macparakeet/pull/1007),
[#1008](https://github.com/moona3k/macparakeet/pull/1008),
[#1011](https://github.com/moona3k/macparakeet/pull/1011), and
[#1017](https://github.com/moona3k/macparakeet/pull/1017) are one experimental
feature. Landing them as four sequential merges would put `main` through states
where confirmation does not reserve a voice, enrollment trusts a cached
observation, and later layers have to rewrite earlier ones. Independent
architecture and fresh-eye reviews agreed: **one maintainer integration PR**.

`AppFeatures.voiceProfilesEnabled` stays `false`. Merging does not enable a
stable release, close #662, or establish recognition accuracy. DEBUG builds may
opt in with `--enable-voice-profiles`; the preference still defaults off and
still requires consent plus meeting speaker detection.

| PR | Reviewed starting head | Contribution kept |
|---|---|---|
| [#1007](https://github.com/moona3k/macparakeet/pull/1007) | `7d564da4` | Permission notice and enrollment after naming |
| [#1008](https://github.com/moona3k/macparakeet/pull/1008) | `0bda7b33` | Read, confirm and dismiss suggestions |
| [#1011](https://github.com/moona3k/macparakeet/pull/1011) | `66c3bfd0` | Profile management and deletion |
| [#1017](https://github.com/moona3k/macparakeet/pull/1017) | `34eccecf` | Documentation, explicit assignment and further fixes |

Contributor commits remain in the integration ancestry. The integration branch
is `review/voice-profiles-20260915`, based on `origin/main` `69e8e834`. All four
PRs conflicted with that main. #1017's old CI failure
(`34958722647`, `MeetingAutoStartCoordinator`) is already resolved on main.

#662 asked for recurring unnamed voices across recordings, naming prompts after
configurable occurrence counts, and name reuse. This implementation covers
explicitly enrolled named voices in meetings. Candidates are never matched to
one another. Recurring-unknown discovery remains out of scope.

## Why a combined PR

Later PRs fix identity bugs in earlier layers. Uncommitted reviewer hardening
rewrites `confirm`, `assign`, `claimProfile`, `updateProfile`, and the service
type across the stack. #1017 also added an unrelated 528-line speaker
consolidation CLI simulator for #944; that sim is removed here and kept in
contributor history.

Merging #1007 alone would land confirmation writing links through whole-profile
`save` rather than `claimProfile`. Merging #1008 alone would keep
`enroll(observation:)` as the UI path that #1017 replaced with live-candidate
resolve.

## Blocking findings addressed

- **Consent boundary:** transcript actions used the administration read
  exception. Recognition now has a gated read and preflight before changing a
  label; disabled recognition still permits management and deletion.
- **Stale enrollment:** accepting an offer resolves the live stored candidate.
  Offers also validate effective speaker name and correction state.
- **Identity reservation:** confirmation and assignment both use atomic
  `claimProfile`. Holder/suggestion UI updates after mutations.
- **Write ordering:** preflight → awaited label correction → profile mutation.
  Labels remain when later profile persistence fails, with copy that says so.
- **Profile rename races:** repository `updateProfile` writes intended fields
  in a transaction instead of saving a stale whole-profile snapshot.
- **Retired models:** explicit assignment records the identity without learning
  an incompatible vector.
- **Undo during the identity write:** undo/redo are refused while
  `isApplyingVoiceIdentity` is set. After completion, undo reverts labels, not
  confirmed links.
- **Meeting capture tracks:** `microphone` / `system` (`Me` / `Others`) cannot
  claim a profile from the overview menu or from `assign` / `confirm` /
  `validateAssignment`. A link on `Me` would hide that voice from the real
  clusters in the same transcript, with no in-product repair except deleting
  the profile.
- **Corrected assignments:** moving a confirmed link to a different profile
  unlearns this recording's sample from the previous profile. A misclick must
  not keep teaching the wrong name after the user names the speaker correctly.
- **`claimProfile` default:** the concrete method now defaults to preserving a
  terminal decision (`replacingUserDecision: false`). Assignment still passes
  `true` explicitly.

## Reviewer judgment

Wrong-person learning is worse than a missed suggestion. Tradeoffs preserve
abstention, explicit identity choices, and conservative learning. Label-before-
learn is kept: a correct label plus a profile that did not learn is recoverable;
the reverse is not.

`SpeakerVoiceprintService` is an actor so Forget All cannot interleave between
claim, exemplar insert, and profile update. Repository transactions still own
individual writes. Actor isolation does not protect a second process.

Independent reviews (`claude -p --model fable` architecture; two
`claude -p --model opus` fresh-eye passes; requested `opus5` / `fable5.1`
aliases are not configured locally) agreed on the combined PR, the actor,
label-before-learn, the capture-track guard, and unlearning a corrected
assignment. Follow-ups they named and that this PR does **not** take:

- Persist "Not now" enrollment refusal per (transcription, fingerprint, speaker).
- Delete retained candidates on consent withdraw without deleting enrolled
  profiles (`forgetAllVoices` is the wrong tool; enrolled voices must remain).
- Hop GRDB I/O off the actor executor.
- In-flight guards on the admin rename/forget sheet.

Those are follow-ups while the flag is off, not merge hostages.

## Simplicity and documentation

The permission notice describes the product choice without assigning legal
responsibility. Documentation distinguishes logical expiry from physical
disk/backup deletion, applied names from private voice metadata, and tested
exports from inspected support boundaries. Management displays the latest
comparison rather than calling it a historical closest match.

Contract: `spec/contracts/speaker-voiceprints.md`. Privacy help:
`docs/voice-profiles-privacy.md`. Plan:
`plans/active/2026-07-03-speaker-voiceprints.md`.

## Verification

Focused, settled-tree runs (no files modified during the build):

```text
swift test --filter 'TranscriptionVoiceEnrollmentTests|SpeakerVoiceprintServiceTests|SpeakerProfileRepositoryTests|VoiceProfilesViewModelTests|VoiceProfileFeatureGateTests|TranscriptionSpeakerCorrectionViewModelTests|SpeakerCorrectionServiceTests|SpeakerCorrectionRepositoryTests|SpeakerCorrectionTests'
# 237 tests, 0 failures
```

Consent and gate:

```text
swift test --filter 'testTurningRememberSpeakersOnAsksForConsentFirst|testAcceptingConsentRecordsTheDateAndTurnsThePreferenceOn|testDecliningConsentLeavesThePreferenceOff|testTurningItOnAgainDoesNotReaskOnceConsentIsOnRecord|testWithdrawingConsentAlsoTurnsThePreferenceOff|testTheResolvedGateFollowsConsentWhenTheFeatureIsAvailable|testTurningThePreferenceOffKeepsTheConsentDate|VoiceProfileFeatureGateTests'
# 11 tests, 0 failures
```

The local full suite is reserved for one final run on the committed tree. No
user recordings or database were modified by this review.

## Remaining release gates

- Held-out real-meeting precision and coverage, unknown speakers, changed
  microphones, overlap, brief speech and mixed clusters.
- Measured processing/memory/storage costs for the exact model and policy.
- Native permission, enrollment, assignment, deletion and expiry qualification.
- Explicit approval to enable the stable release flag.

**Confidence:** high in the identified failure modes and the narrow product
boundary; no claim of measured meeting accuracy or native workflow
qualification.
