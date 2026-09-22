# Experimental voice profiles

Voice profiles are disabled by default. A DEBUG build can expose them with
`--enable-voice-profiles`; release builds ignore that argument. This implementation
is available for controlled evaluation, not an accuracy-qualified public release.
The [contract](../spec/contracts/speaker-voiceprints.md) governs behavior.

## How it works

Speaker detection separates voices within one recording. Voice profiles add an
optional name that can be suggested in later meetings. Suggestions always require
confirmation. You can also explicitly choose a saved voice for a meeting speaker.

Enable meeting speaker detection, turn on **Remember speakers**, and acknowledge
the permission notice. After a meeting, rename a speaker and choose **Remember**
if a suitable temporary sample remains. Simply typing a label does not enroll a
voice. Ordinary transcript editing continues to work without voice profiles.

This version covers meeting recordings. It does not group recurring unnamed voices
across historical recordings or offer a configurable recurrence threshold. Those
parts of [issue #662](https://github.com/moona3k/macparakeet/issues/662) remain outside
this implementation's scope. Temporary samples and identity writes apply to
diarized system-audio clusters, not the microphone (`Me`) capture track.

## What is stored locally

| Data | Purpose | Retention |
|---|---|---|
| Named profile and samples | Compare future meeting speakers to a person explicitly enrolled | Until deleted; at most ten samples, one per source recording |
| Temporary candidate | Let the user enroll a speaker after the meeting finishes | Seven-day expiry per stored row |
| Profile links | Record suggestions, confirmations and refusals for a transcript version | Until associated profile or transcript deletion |
| Match journal | Inspect local scoring decisions for calibration | 90 days |

Each sample is a 256-component vector, not an audio recording. Voice profiles
contain sensitive biometric information. Enable the feature only with permission
from the people being recorded. Audio retention remains a separate setting.

Candidates are never compared with each other. Expired candidates are unavailable
for enrollment. Cleanup runs on reads/writes, at launch and hourly while the app
runs; it resumes at the next launch after shutdown. Expiry does not promise
immediate physical erasure from disk pages or user-managed backups.

Accepting enrollment resolves the current stored candidate. An old prompt cannot
recreate a candidate that expired or was deleted. Successful sample insertion
consumes its candidate; failed or rejected insertion preserves it until expiry.

## Turning off and deleting

Turning **Remember speakers** off stops recognition and further enrollment.
Withdrawing permission also clears the acknowledgement. Existing saved voices
remain until you delete them; management stays available.

Open **Settings → Capture → Meetings → Voice profiles → Manage…**, or the voice
profile cleanup control in **Settings → System → Reset & Cleanup**. Delete a
profile, selected profiles, individual samples while another remains, or all
voices. To remove a profile's last sample, forget that profile.

**Forget all** clears profiles, samples, links, temporary candidates and the
journal in one database transaction. It leaves source audio, transcripts and
already-applied names intact. Profile deletion also leaves transcript labels intact.

## Data boundaries

Voice vectors, profile IDs and match metadata are excluded from transcript
exports, CLI transcript projections, telemetry, support bundles and external AI
context. Names you explicitly apply become ordinary transcript labels and can
appear wherever that transcript is exported or shared.

Populated-table tests cover app export projections and CLI exports. Support and
diagnostic builders are inspected and covered by their existing tests; this is
not a claim of populated-table testing on every outward surface. Telemetry records
only the on/off preference, subject to the app's telemetry setting.

## Limits and feedback

Recognition can abstain when speech is brief, voices are ambiguous, or recording
conditions change. A mixed-speaker diarization cluster cannot be repaired by a
voice profile. The current experimental duration gates are three seconds for
matching and fifteen seconds for retaining or learning a sample.

Management shows the latest evaluation distance, recognition history and whether
samples use an older model. Distance alone does not guarantee a suggestion: the
matcher also requires separation from competing voices. Older-model samples cannot
be matched or learned from a new model; an explicit name assignment can still be
recorded without adding an incompatible sample.

A profile-write failure after a successful label correction leaves the requested
label intact and reports the failure. A corrected label alone does not prove the
profile learned a sample.

Held-out real-meeting accuracy, changed microphones, unknown speakers, overlapping
speech and native permission/deletion flows remain release gates. See the
[plan](../plans/active/2026-07-03-speaker-voiceprints.md#integration-and-release-gates-2026-09-10).
