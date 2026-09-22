# Streaming cursor insertion — research for #449

Date: 2026-09-17. Local working note. Not a GitHub comment.

Question: what is Superwhisper’s “streaming cursor with 1-character-at-a-time output,” and how can MacParakeet ship that as optional delight without slowing the default paste path or breaking dictation insertion?

## What #449 actually asks for

Issue [#449](https://github.com/moona3k/macparakeet/issues/449) (2026-06-07, app 0.6.21) is praise plus one miss:

> streaming cursor with 1-character-at-a-time output (from SuperWhisper). Cutesy and pointless but also kinda nice!!

The maintainer asked for a Superwhisper screen recording. None arrived. The report is still specific enough to identify the feature: **the destination app’s insertion point racing through already-finished text**, not live ASR and not MacParakeet’s overlay preview.

## Superwhisper’s two insertion modes

Superwhisper’s default is the same family as MacParakeet: record, then **paste** the finished string at the cursor. Their changelog documents an experimental alternative: **“Simulate output keystrokes instead of using copy/paste (only works for US QWERTY layout)”** ([Superwhisper changelog](https://superwhisper.com/changelog)).

That keystroke path is the streaming cursor. Users describe the doubled-event bug as “pasting every letter individually” ([r/superwhisper, May 2026](https://www.reddit.com/r/superwhisper/comments/1th4pge/bug_text_is_pasted_twice_after_dictating/)). Community CGEvent typers (e.g. macrowhisper’s `typeText`) loop graphemes with ~10ms sleeps and `keyboardSetUnicodeString`.

Live transcription (words appearing **while** you speak, on some Superwhisper models) is a different feature. #449’s “1-character-at-a-time output” is the post-ASR typewriter, not Parakeet live preview.

## What MacParakeet does today

Canonical insertion is documented in [spec/02-features.md](../../spec/02-features.md) and implemented by `ClipboardService.pasteText`:

1. Snapshot the pasteboard
2. Write the transcript
3. Post Cmd+V (`CGEvent` + layout-aware `v` keycode)
4. Restore the previous clipboard after 500ms unless “Keep dictation on clipboard” is on

`DictationFlowCoordinator` calls that on `.pasteTranscript` after a successful transcription. `dictation_insert` records `paste_ms` as a success-only breadcrumb. `DictationInsertionStyle` is **sentence vs inline capitalization**, not paste vs type — despite one CLI-parity note that mislabels it.

Transforms already replace via AX `kAXSelectedTextAttribute` then clipboard paste (`SelectionReplacementService`). That path is replace-in-place, not a typewriter. Do not reuse it for dictation streaming.

The recording **undo window** is pre-paste (Esc during capture). After paste, native ⌘Z in the target app undoes one paste when insertion was a single Cmd+V. Transforms copy already says “⌘Z to undo where supported.”

The in-flight paste `Task` is **not** the coordinator `actionTask`. `.cancelActionTask` on a finishing restart therefore does not stop a paste already posting events. A 400ms stream makes that existing race user-visible.

## Why naive per-keystroke typing is not “premium”

| Approach | Feel | Cost |
|---|---|---|
| 10ms/char CGEvent loop | Superwhisper-like, mechanical | 200-char paragraph = 2s; ⌘Z undoes one character; IME/CJK fragile if virtualKey is layout-bound |
| Overlay HUD at AX caret, then one paste | Smooth, one undo | Caret bounds/font are missing in Chrome/Electron/Slack — the apps where people dictate |
| Growing clipboard paste | Looks like streaming | Thrash + N undos + restore races |
| AX set selected text each frame | Sometimes coalesces | Unreliable in web views; not the destination caret |

Premium is **short, eased, interruptible motion of the real caret**, with a hard time budget, not a longer wait for the same text.

## Motion design (feel, not a second audio stack)

ChatGPT-style streaming is token-linear. The blissful typewriter is **ease-out with a tiny settle**: the eye catches the caret, the body rushes, the last word lands.

Constraints chosen for this product:

- **Default off.** Off must call the existing `pasteText` / `pasteTextWithAction` path with no extra monitors, sleeps, or event sources.
- **Cap total stream at 420ms** (plus ≤80ms post-caret settle only when streaming actually ran). Short utterances floor at ~180ms so a single word is still visible. Long utterances use **larger batches**, not a longer wait.
- **Extended grapheme clusters** as the atomic unit (`👨‍👩‍👧‍👦` is one batch). Never split UTF-16 surrogates.
- **Batch to a 120Hz schedule**, not one event per character. ~24–48 HID events max. Unicode `keyboardSetUnicodeString` (virtualKey 0) so this is not Superwhisper’s QWERTY-only experiment.
- **Reduce Motion** (`NSWorkspace.accessibilityDisplayShouldReduceMotion`): instant paste, same as off.
- **Interrupt flushes remainder as one Unicode event**, then lets the user’s key through. Do not abandon text. Do not leave a half sentence. Triggers: keyDown (not our tagged events), mouse down, scroll, Task cancellation (new dictation / dismiss).
- **Do not use the clipboard for the stream itself.** “Keep dictation on clipboard” still copies once after a successful insert. Paste fallback (event source failure, reduced motion, setting off) keeps today’s snapshot/Cmd+V/restore.
- **Voice Return / snippet keystroke** fires after the stream (or flush) completes, same 200ms delay as `pasteTextWithAction`.
- **⌘Z after streaming is not one undo.** That is the trade the setting opts into. Document it. Default paste keeps one undo.

## Apple primitives

- `CGEvent.keyboardSetUnicodeString` — documented path for posting Unicode independent of keyboard layout ([CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)).
- Tag posted events with `eventSourceUserData` so a global `NSEvent` monitor can ignore our own stream.
- `NSEvent.addGlobalMonitorForEvents` only for the stream duration; remove in `defer`.
- Accessibility is already required for Cmd+V. Streaming does not add a new TCC prompt.

## Out of scope

Live typing **while** speaking; overlay-only fake carets; Transforms; menu-bar “paste last”; changing sentence/inline style; using streaming as a paste-compatibility workaround for remote desktops (keep-on-clipboard already covers that).
