# MacParakeet 0.8.10

## Publication update (verified 2026-10-31)

[0.8.10 was published on GitHub](https://github.com/moona3k/macparakeet/releases/tag/v0.8.10)
on October 14, 2026 at 04:30 UTC, targeting
`394e630b4af70c814f1176902337a95c99b84f0c`. The release lists
`MacParakeet.dmg` (181,247,157 bytes). The locally installed app reports 0.8.10
and its bundled CLI reports 5.1.0. Source has since advanced; see the
[canonical release table](../../../spec/README.md#release-channels-and-feature-flags).

These are publication/version observations, not a new artifact-signature or
hardware qualification. The October 31 review could not read the live Sparkle
feed (HTTP 403) and did not repeat notarization, an upgrade, or a DMG mount.
The [review evidence](../../audits/2026-10-31-app-cli-parity/README.md) records
that limit. No DMG hash or unobserved validation receipt is inferred here.

## Historical preparation record

The remainder records the candidate preparation and its then-outstanding
checks. Publication above supersedes the old “not yet published” status; it
does not retroactively turn every preparation gate into verified evidence.

- [GitHub release body](github.md): changes since 0.8.9, the CLI 5.1.0 default-model note, and a link to 0.8.9 for people skipping that release.
- [Sparkle description](sparkle.html): 0.8.10 changes plus a short 0.8.9 recap. Sparkle shows only the newest item, so the recap has to stand alone. The feed should keep previous entries.

## Candidate

- Code base: `394e630b4`, the #1255 merge. The app and DMG are built from that commit. Do not build from an older `release/0.8.10` commit.
- Merged after the preparation commit (`8f6a87e20`):
  - #1247 (`911efb080`) fixes a regression introduced during this cycle. The meeting-notes status caption from #1209 (`d5ad0384f`) used vertical `fixedSize`, so opening a meeting result with notes off or missing grew the window past the screen. 0.8.9 never had the caption, so the user notes do not list it.
  - #1251 (`db8c77c46`) fixes a regression from #1243: Settings → Permissions → Screen & System Audio **Allow** did nothing after a denial. It now opens System Settings. Also not user-facing relative to 0.8.9.
  - #1254 (`852c45bd1`) lets AI cleanup finish a transcript longer than about seven minutes. Cloud requests wait 300 seconds, and a long transcript is cleaned in sections of at most 12,000 characters. This is in the user notes.
  - #1255 (`394e630b4`) keeps the result page quiet when the meeting has no notes. A **Notes not included** control appears only when current notes were left out of the result. 0.8.9 never showed the old caption, so the user notes do not list it.
- Not included: #1248 (AEC reference lookahead for #920) is held for a later release.
- This preparation commit bumps the bundled CLI from 5.0.0 to 5.1.0 and adds these notes. Fill in the signed commit, build number, DMG size, and SHA-256 at publication. Do not copy the 0.8.9 artifact identity forward.

## Known limits

- [#1199](https://github.com/moona3k/macparakeet/issues/1199) is the 16 GB M2 Air / Teams memory report. Cleaned-mic rendering and the during-call preview backlog are bounded in this candidate. Those measurements do not close the Air report. Release notes describe the memory bounds and do not say the freeze is fixed.
- [#1228](https://github.com/moona3k/macparakeet/issues/1228) is fixed here. Older meetings keep their stored speaker labels until re-transcribed.
- [#920](https://github.com/moona3k/macparakeet/issues/920), [#912](https://github.com/moona3k/macparakeet/issues/912), and [#1214](https://github.com/moona3k/macparakeet/issues/1214) remain open and are already true of 0.8.9. #1248 targets #920 and is not in this release.
- Holding one dictation shortcut and pressing another configured dictation chord keeps recording, as #1210 intends, but that chord's keystroke also reaches the front app. Rare; deferred to 0.8.11.
- Keychain reads no longer prompt. A key saved by the CLI or a dev build can return a blocked-access error; AI Setup explains how to allow it in Keychain Access, and the key is kept.
- If live preview falls behind, some live words may skip and later preview words can look early. The saved recording is kept.

## Gates

Voice Control, cross-recording Ask, voice profiles, encrypted share links, and in-process MLX stay off in release builds. **0.9.0** stays reserved for qualified Voice Control.

The app and CLI both default Anthropic to `claude-sonnet-5-5` and OpenRouter to `anthropic/claude-sonnet-5.5`. New Summary prompts include meeting notes in both surfaces; existing libraries keep their saved preference. Meeting URL controls default off in the app and are not a CLI command. Diarized meetings label unclaimed system words Unattributed and leave them out of `speakerCount` in both surfaces.

## Preparation-time verification limits

Signed app and DMG notarization, stapling, Gatekeeper, the mounted CLI version, a Sparkle upgrade, website changelog deployment, and physical microphone, Bluetooth, or 16 GB capture. Those belong to the publication steps in [distribution](../../distribution.md).
