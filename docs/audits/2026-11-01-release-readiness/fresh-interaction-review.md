# Fresh interaction review

Reviewed candidate `93e7b3944f4cd4011582aea5f85389bbb32bd157` against stable
`394e630b4` on 2026-11-01. The checkout was clean when inspected. This is an
independent source review; earlier audit findings and verdicts were not used.
No code was changed, and no build, test suite, native UI action, network helper,
or external service was run by this reviewer.

## Findings

No additional actionable P1/P2 runtime regression was established in the
assigned interaction scope. This is a source-review result, not native release
acceptance or proof that every input configuration works.

## Coverage and reasoning

### Keyboard output, hotkeys, clipboard, and streaming insertion

- Read the System subsystem README and dictation-shortcuts contract; compared
  the generated-event helper and all changed posting/listening callers.
- Paste, post-paste keystrokes, selection copy/replacement, streaming Unicode,
  and Voice Control Unicode use the marked session-entry path. Event pairs
  are allocated before either event is posted. Command-layout key resolution
  remains in the copy/paste paths.
- Hotkey snapshots reject marked events before gesture or release tracking;
  global shortcuts and Transforms also reject the marker. Bare Fn now reads
  HID ordinary-key state, while custom-trigger/peer recovery keeps session
  semantics and unmarked observed-release recovery remains intact.
- Traced interruption through the production background tap, playback lock,
  invalidation, coordinator fallback, and cancellation. A failed interrupt
  drain permanently stops posting; the zero-commit error path stops posting
  before waiting for tap teardown and reports partial insertion if an
  interruption was observed. The coordinator copies recovery text without
  automatically pasting it and suppresses success/post-actions on cancellation.
- Inspected focused streaming regression cases for failed drain before/after
  first commit, cancellation after failure, initial-post failure, and
  interruption during teardown. These test definitions were inspected, not run.

### Dictation URL control

- Read the URL-control contract and followed parser, launch buffer,
  AppDelegate, runtime preference, Settings binding, and coordinator dispatch.
- Consent is independently default-off. Receipt and dispatch check consent;
  launch failure discards pending commands. Onboarding and quit guards apply
  at dispatch. URL starts use the normal persistent dictation flow and the
  command state mapping avoids replacing processing/undo/paste work.
- Parser rejects query/fragment/credential/port/path aliases and bounds input;
  distribution and development schemes are selected separately.

### Sounds

- Read configuration, controller, import library, Settings UI, SoundManager,
  capture-cue call sites, and package resource declaration.
- Configuration defaults preserve system cues. Imported audio has bounded
  reads and duration validation, is copied to managed UUID filenames, and
  does not require the source to remain present. Replacement commits only
  after validation/player creation; cancellation before commit removes the new
  copy. Generation checks prevent stale launch restore replacing a new import.
- Preview and capture use separate player instances; fallback uses prepared
  system sounds. Reset/replacement cleanup only targets unreferenced managed
  basenames, with symlink rejection. Bundled WAV files are under the processed
  SwiftPM Resources directory.

### Settings, vocabulary, and text matching

- Read the TextProcessing README and custom-word-deletion contract. Traced
  presentation/reset, failed-read state, mutation guards, deletion snapshot,
  import completion reload, and backup export lifecycle through their callers.
- Failed word reads retain the last loaded list while disabling changes;
  selection and search reset when presentation begins outside an active delete.
  Backup busy state spans export construction, panel/write, and result, and
  failure/cancel paths settle it. Successful import reloads words and snippets.
- Custom words and snippets share escaped literal matching with Unicode-word
  adjacency guards. Meeting token optimization falls back to full scans for
  punctuation/compound literals, preserving the newly supported terms.
- Inspected Settings search visibility changes and their live voice-profile
  state inputs, responsive layout additions, sound controls, and URL-control
  binding. Declarative catalog size is not treated as a runtime release blocker.

### Video playback and review fixes

- Read the playback contract and full VideoStreamService/MediaPlayerViewModel;
  traced Show Video, Hide Video, initial presentation, row changes, cleanup,
  retained-audio conversion, and subtitle call sites.
- Remote combined streams retain the URL cache path; separate streams are
  downloaded into a unique owned temporary directory and both tracks are
  explicitly mapped for FFmpeg stream copy. Missing/empty/oversized outputs
  fail, and fallback media never replaces the persisted retained-audio path.
- Process output uses files rather than exit-before-drain pipes; reads are
  bounded and surfaced errors sanitized. Cancellation/timeout awaits the
  shared process waiter's termination flow before preparation cleanup.
- Ownership transfers to VideoPlaybackResource only on success. Player items
  detach before releasing resources. Cancelled completions cannot install
  media or stop a newer timer; stage updates inspect cancellation.
- Checked `ee3f9b87e` and `d66cfae0f` behavior in the final source: Hide Video
  restores retained audio after direct-load failure/cancellation, including
  legacy conversion; already-loaded audio is preserved. Conversion completion
  rechecks cancellation after persistence. Duration metadata checks current
  player identity after its await. Row-change UI calls cleanup before loading.
- Inspected test definitions for resource lifetime, superseded completion,
  preparation failure, Hide Video success/failure restoration, legacy audio,
  persistence suspension, metadata ownership, and controlled helper termination.

## Remaining acceptance evidence

- Physical Fn and alternate-key sequences, third-party remappers/session-only
  remote input, Jump Desktop, and real Accessibility delivery are not proved by
  inspecting synthetic event tests. Exercise hold/release, double-tap, copy,
  paste, and streaming interruption in the intended native applications.
- Packaged URL delivery needs background `open -g` acceptance with focus held
  in a real text editor, including default-off, enabled start/stop, startup,
  and a busy transcription/paste. Parser/router source coverage does not prove
  Launch Services or focus behavior.
- Actual speakers/headphones, route changes, preview/import, and capture cue
  audibility require native audio acceptance. This review did not decode or
  listen to the bundled WAVs.
- Live YouTube format availability, download behavior, FFmpeg interoperability,
  AVPlayer decoding, seeking, playback rate, and audio/video synchronization
  remain provider/native checks. The documented 512 MiB helper limit depends
  on size metadata and is not a hard peak-disk quota.
- Responsive Settings, search destination scrolling, alert/sheet behavior, and
  keyboard/accessibility navigation were source-reviewed, not visually tested.

The parent owns focused execution and release verification. No prior test
receipts, native acceptance claims, or previous audit verdicts are promoted
to fresh execution evidence in this report.
