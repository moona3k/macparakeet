# MacParakeet 0.8.8

This update makes everyday dictation more dependable and gives you more control over the text you keep. Recover a failed dictation, edit a transcript or saved AI result, choose different AI models for cleanup and analysis, and manage prompts from the Library.

Speech recognition continues to run locally. Cloud AI remains optional and uses the provider you configure.

## Dictation that is easier to start, stop, and recover

- **Retry failed dictations from History.** When recognition fails after recording, MacParakeet keeps the recording with the failure reason so you can retry. This requires Save dictation history. After a successful retry, audio follows your Save audio recordings setting. [#1146](https://github.com/moona3k/macparakeet/pull/1146)
- **More reliable hold-to-talk and rapid restarts.** Fixes cover delayed Fn releases, stale key state, cancellation overlapping a new take, and stalled live recognition delaying Stop. Keyboard monitoring also moves off the main UI thread so a busy interface is less likely to delay your shortcut. [#1121](https://github.com/moona3k/macparakeet/pull/1121), [#1143](https://github.com/moona3k/macparakeet/pull/1143), [#1144](https://github.com/moona3k/macparakeet/pull/1144), [#1147](https://github.com/moona3k/macparakeet/pull/1147), [#1148](https://github.com/moona3k/macparakeet/pull/1148)
- **Instant Dictation on macOS 27:** fixes a repeated microphone reacquisition loop. [#1103](https://github.com/moona3k/macparakeet/pull/1103)
- **Two optional shortcuts:** copy a dictation to the clipboard without pasting, or request AI polish for one utterance. AI polish requires the AI Formatter master switch and a configured provider. Both shortcuts start unset. [#1066](https://github.com/moona3k/macparakeet/pull/1066), [#1065](https://github.com/moona3k/macparakeet/pull/1065)
- **Choose how dictation feels.** Optional capture sounds, top- or bottom-center pill placement, and a setting that lets Escape pass through instead of cancelling a recording. Sounds are off by default; Escape still cancels by default. [#1055](https://github.com/moona3k/macparakeet/pull/1055), [#1068](https://github.com/moona3k/macparakeet/pull/1068), [#1058](https://github.com/moona3k/macparakeet/pull/1058)
- **Say “question mark” or “exclamation mark” in Clean mode** to insert punctuation, with a literal-phrase escape when you mean the words themselves. [#1063](https://github.com/moona3k/macparakeet/pull/1063)

## A more useful Library

- **Edit directly in the reading view.** Correct or omit transcript passages while retaining the original recognition evidence and audio. Corrections carry through exports and AI context. Longer transcripts are more responsive, and Done stays reachable while you scroll. [#1117](https://github.com/moona3k/macparakeet/pull/1117), [#1155](https://github.com/moona3k/macparakeet/pull/1155), [#1156](https://github.com/moona3k/macparakeet/pull/1156)
- **Edit saved AI results in place.** Refine a summary or action list without generating it again. Regeneration protects edited content, switching result tabs preserves an unfinished draft, and a reload cannot turn a stale draft into an overwrite of newer edits — nor can a failed reload be mistaken for the result having been deleted. If the result you're editing is genuinely removed elsewhere, Copy Draft copies your unsaved edit to the clipboard so you keep it, while Discard Draft abandons it and closes the editor. [#1061](https://github.com/moona3k/macparakeet/pull/1061), [#1176](https://github.com/moona3k/macparakeet/pull/1176), [#1180](https://github.com/moona3k/macparakeet/pull/1180), [c9b5801](https://github.com/moona3k/macparakeet/commit/c9b5801872e6b0e513a348e44dc38c6a7d43c959)
- **Regenerate results without duplicate tabs.** Progress stays in the existing tab position, and cancellation restores the saved result. Older results without transcript tracking no longer show a freshness banner; confirmed transcript changes still do.
- **Prompts now live in Library.** Open the prompt manager from the Library toolbar. Notes offer more writing space, and the Meetings overview fits compact windows more comfortably. [#1150](https://github.com/moona3k/macparakeet/pull/1150), [#1158](https://github.com/moona3k/macparakeet/pull/1158), [#1159](https://github.com/moona3k/macparakeet/pull/1159)
- **Safer saves and imports.** Transcript saves preserve newer record changes, edited text stays consistent with search, and directory discovery runs off the UI thread with cancellation. Meeting recovery preserves recordings whose contents cannot yet be safely classified and respects explicitly cleared notes. [#1181](https://github.com/moona3k/macparakeet/pull/1181), [#1173](https://github.com/moona3k/macparakeet/pull/1173)

## More control over AI and selected text

- **Separate cleanup from analysis.** Choose one provider/model for cleanup and another for summaries and chat, or let both inherit your default. Transforms continue to use Default AI. The app and CLI share these routes. In-flight work retains its captured configuration. [#1071](https://github.com/moona3k/macparakeet/pull/1071), [#1176](https://github.com/moona3k/macparakeet/pull/1176)
- **Apple Intelligence, optionally on-device.** Eligible Macs running macOS 26 or later can use Apple's system model without an API key. Enable Apple Intelligence in System Settings first. Its small context window suits short rewrites and cleanup better than full meeting summaries; oversized AI Formatter input falls back to deterministic cleanup instead of being truncated. [#1077](https://github.com/moona3k/macparakeet/pull/1077), [#1181](https://github.com/moona3k/macparakeet/pull/1181)
- **Keep complete text when AI formatting fails.** Truncated or length-limited formatter responses fall back to the complete deterministic cleanup result. [#1181](https://github.com/moona3k/macparakeet/pull/1181)
- **Choose the language of meeting AI results:** follow the transcript by default, or request English, Polish, German, Spanish, French, Portuguese, Japanese, or Chinese. This controls generated results, not speech recognition. [#1060](https://github.com/moona3k/macparakeet/pull/1060)
- **Run saved Transforms from the menu bar**, including ones without a keyboard shortcut. The action uses the selection in the app from which you opened the menu. [#1064](https://github.com/moona3k/macparakeet/pull/1064)

## Setup and speech models

- **Practice during first run.** A shorter four-step setup lets you rehearse the actual shortcut while speech models prepare, then try a real dictation once they are ready. Practice can be skipped. [#1125](https://github.com/moona3k/macparakeet/pull/1125)
- **Orukeet preview.** An optional Parakeet variant is available in speech settings; Parakeet v3 remains the default. Orukeet needs a separate download and does not provide live dictation preview or recognition-time custom vocabulary. [#1091](https://github.com/moona3k/macparakeet/pull/1091)
- **Updated automatic speaker detection.** Automatic diarization now uses Nemotron, supporting up to eight speakers per analyzed source. Fixed speaker-count modes retain their existing backend. Speaker-model setup includes an additional download; existing installations may need one connected warm-up before returning to offline use. Speaker labels can still need correction. [#1152](https://github.com/moona3k/macparakeet/pull/1152)
- **Replace an entire vocabulary during import.** Review the replacement before confirming. It replaces manual words and snippets while retaining unmatched learned recognition terms; the existing Add new entries and Replace duplicates choices remain available. [#1067](https://github.com/moona3k/macparakeet/pull/1067)

## Automation: bundled CLI 4.7.0

The app bundles CLI 4.7.0, up from 4.4.0 in 0.8.7. New commands edit saved meeting AI results with conflict detection, apply reversible batches of transcript corrections, and manage the shared cleanup/analysis AI routes. Failed dictations can be retried with `retranscribe --kind dictation --update`.

Existing commands remain available. Scripts reading dictation history should handle the new `status: "error"` value. See the [CLI changelog](https://github.com/moona3k/macparakeet/blob/v0.8.8/Sources/CLI/CHANGELOG.md) for exact command, JSON, and compatibility details. The standalone Homebrew CLI follows its own release channel.

## Before updating

- Requires **Apple Silicon and macOS 14.2 or later**. Apple Intelligence additionally requires an eligible Mac, macOS 26+, and enabled system models.
- The new cross-recording Ask workspace, Jev Voice Control, voice profiles, encrypted share links, and in-process MLX remain experimental and disabled in normal release builds. They are not new public features in 0.8.8.
- Download `MacParakeet.dmg`, open it, and drag MacParakeet to Applications, or choose **Check for Updates…** in the app.

[All changes since 0.8.7](https://github.com/moona3k/macparakeet/compare/v0.8.7...v0.8.8)
