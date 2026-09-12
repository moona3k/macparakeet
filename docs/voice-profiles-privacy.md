# Voice Profiles — what is stored, and what that means

> Source material for user-facing help and the privacy page. The feature ships
> disabled (`AppFeatures.voiceProfilesEnabled == false`); nothing below is live
> for users yet. Behaviour is specified in
> [F13a](../spec/02-features.md) and
> [ADR-010's 2026-09 amendment](../spec/adr/010-speaker-diarization.md).

## The problem it solves

MacParakeet can tell speakers apart inside one recording. It cannot carry that
across recordings: the person who was "Others 1" on Monday may be "Others 2" on
Tuesday, because those labels describe positions in a file, not people. So a
name has to be typed again for every meeting.

Voice profiles let you name someone once. Later meetings then *suggest* that
name. They never apply it.

## What is stored

Two different things, with different lifetimes.

**Voice samples** belong to a person you named. Each is 1024 bytes of numbers
describing voice characteristics — not audio, and not reversible into audio.
A profile keeps at most ten, one per recording. They last until you delete them.

**Waiting voices** belong to nobody. When a meeting ends, MacParakeet keeps the
numbers for each detected speaker so you can still name them afterwards —
naming usually happens later, and by then the calculation is long gone. These
are deleted after **seven days** if you never name anyone, and immediately once
you do.

Waiting voices are never compared with each other. MacParakeet cannot tell you
"this unknown person appeared in five meetings", and is not built to.

## Why you are asked for permission

A voice sample is biometric data, and several laws regulate keeping one —
Illinois's BIPA, Texas's CUBI, and the GDPR where it applies. What each of them
requires differs: BIPA centres on written notice and a signed release before
collection, while the GDPR treats biometric data used to identify someone as a
special category needing an explicit lawful basis. The duties fall on whoever
records the meeting, which is you rather than MacParakeet — it stores nothing on
its own and nothing leaves your Mac.

We are not able to tell you which rules apply to your situation, and this is not
legal advice. What MacParakeet does is make the choice explicit and reversible:
turning "Remember speakers" on asks you to confirm you have the participants'
permission, before anything is stored. Declining stores nothing.
You can withdraw it at any time, which switches the feature off; your existing
saved voices stay until you delete them, and the screen that deletes them
remains available.

## What never happens

- **Nothing leaves your Mac.** No voice data appears in any export (JSON, text,
  Markdown, SRT, VTT, DAPT), in the command-line tool, or in a diagnostic bundle
  you send us. Automated tests assert this per table, on every one of those
  surfaces.
- **No audio is kept for this.** Only the numbers. Audio retention is a separate
  setting and is unaffected.
- **No name is applied automatically.** A suggestion is an offer with two
  buttons. A wrong name applied silently is worse than an unnamed speaker.
- **Nothing is measured about who you meet.** The app reports whether the
  setting is on or off, and nothing else — no names, no counts, no match scores.

## Deleting

Settings → Capture → Meetings → **Voice profiles → Manage…**, or Settings →
System → Reset & Cleanup → **Voice profiles**.

You can delete one sample, one person, the selected people, or everything. The
"forget everything" path also removes voices still waiting to be named — they
belong to no profile, so nothing else would ever reach them.

**Deleting a voice never changes names already written to your transcripts.**
Those are ordinary text edits and stay exactly as they are.

## When it will not work, and why

The Voice Profiles screen says which of these applies to each saved voice.

| What you see | What it means |
|---|---|
| Never compared against a recording yet | No meeting has been scored against it |
| Never recognized. Closest match was 0.34, and 0.25 or lower is needed | It is being compared, but this voice sounds too different — often a different microphone or a noisier room |
| Saved with an older voice model | A MacParakeet update changed how voices are measured. Old samples cannot be compared. Delete it and name the speaker again in a recent meeting |

Two other reasons a speaker is never offered: they spoke for less than 15
seconds in the meeting, or the recording finished more than seven days ago and
the waiting voice has expired.
