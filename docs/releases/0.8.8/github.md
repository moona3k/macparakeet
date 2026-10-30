# MacParakeet 0.8.8

Retry failed dictations, edit transcripts and saved AI results, and browse your Library faster. This update also adds separate AI model choices for cleanup and analysis, more output languages, and automatic speaker detection powered by Nemotron.

## Dictation

- **Retry failed dictations from History.** If recognition fails, the recording and failure reason stay in History so you can try again. Requires Save dictation history. After a successful retry, audio follows your Save audio recordings setting. [#1146](https://github.com/moona3k/macparakeet/pull/1146)
- **More reliable Fn shortcuts and rapid restarts.** Fixes delayed key releases, stuck shortcut state, and cancelled takes interfering with a new recording. A busy interface is less likely to delay shortcuts, and stalled live recognition no longer holds up Stop.
- **Instant Dictation on macOS 27.** Fixes a loop that repeatedly tried to reopen the microphone.
- **AI-polished dictation shortcut.** Assign an optional shortcut to request AI polish for one dictation. It starts unset and requires AI Formatter to be enabled with a configured provider. [#1065](https://github.com/moona3k/macparakeet/pull/1065)
- **Capture sounds and controls.** Choose optional start/stop sounds, place the recording pill at the top or bottom of the screen, or let Escape pass through instead of cancelling. Sounds are off by default; Escape still cancels by default. [#1055](https://github.com/moona3k/macparakeet/pull/1055), [#1068](https://github.com/moona3k/macparakeet/pull/1068), [#1058](https://github.com/moona3k/macparakeet/pull/1058)
- **Spoken punctuation in Clean mode.** Say “question mark” or “exclamation mark” to insert punctuation. Say “literal question mark” to keep the words. File, URL, and meeting transcription keep these phrases as spoken. [#1063](https://github.com/moona3k/macparakeet/pull/1063)

## Library and editing

- **Faster loading and scrolling**, especially in libraries with many recordings and video thumbnails. [#1189](https://github.com/moona3k/macparakeet/pull/1189)
- **Edit in the transcript reading view.** Correct or omit passages while retaining the original transcript and audio. Corrections carry through to exports and AI context. Long transcripts are more responsive, and Done stays visible while you scroll. [#1117](https://github.com/moona3k/macparakeet/pull/1117)
- **Edit saved AI results.** Refine a summary or action list without generating it again. Switching tabs preserves your draft, and saving protects against overwriting newer edits. If a result is deleted elsewhere, you can still copy your unsaved draft. [#1061](https://github.com/moona3k/macparakeet/pull/1061)
- **Regenerate without duplicate tabs.** Progress stays in the existing tab, and cancelling restores the saved result. Regeneration will not overwrite edits made while it is running. Older results no longer show an update warning just because their original transcript version was not recorded. Results still warn when the transcript has changed.
- **Manage Prompts from the Library toolbar.** Notes have more writing space, and the Meetings overview fits compact windows better. [#1150](https://github.com/moona3k/macparakeet/pull/1150)
- **Safer saves, imports, and recovery.** Saving a transcript preserves other recent changes to the recording, and search reflects your edits. Folder imports stay responsive and can be cancelled. Recovery keeps recordings when their audio cannot be verified and preserves notes you intentionally cleared.

## AI and Transforms

- **Separate models for cleanup and analysis.** Choose a provider and model for Dictation & cleanup and another for Meetings & library, or let both use your default. Transforms continue to use Default AI. The app and CLI use the same choices; work already running keeps the settings it started with. [#1071](https://github.com/moona3k/macparakeet/pull/1071)
- **Apple Intelligence support.** Use Apple's on-device model without an API key on eligible Macs running macOS 26 or later. Enable Apple Intelligence in System Settings first. It is best suited to short rewrites and cleanup because it accepts less text than larger models. AI Formatter uses standard cleanup for text that exceeds its limit. [#1077](https://github.com/moona3k/macparakeet/pull/1077)
- **Keep the full text when AI formatting fails.** Incomplete or length-limited AI responses fall back to standard cleanup without cutting down the transcript.
- **More languages for AI results.** Follow the transcript's language or choose a language from the expanded searchable picker. This applies to prompt results for all transcript sources and does not change speech recognition. [#1188](https://github.com/moona3k/macparakeet/pull/1188)
- **Run Transforms from the menu bar**, including saved Transforms without a keyboard shortcut. They use the text selected in the app where you opened the menu. [#1064](https://github.com/moona3k/macparakeet/pull/1064)

## Setup and speech models

- **Four-step onboarding with dictation practice.** Rehearse your shortcut while speech models prepare, then try a real dictation. Practice can be skipped. [#1125](https://github.com/moona3k/macparakeet/pull/1125)
- **Orukeet preview.** Try an optional Parakeet variant in speech settings. Parakeet v3 remains the default. Orukeet requires a separate download and does not support live dictation preview or recognition-time custom vocabulary. [@Nathan-Roll1](https://github.com/Nathan-Roll1) contributed the MacParakeet integration for [Oruk’s Orukeet model](https://huggingface.co/oruk/orukeet). [#1091](https://github.com/moona3k/macparakeet/pull/1091)
- **Nemotron automatic speaker detection.** Automatic mode supports up to eight speakers per analyzed source. Explicit speaker-count settings continue to use Community-1. An additional model download and initial setup may be needed before offline use. Speaker labels may still need correction. [#1152](https://github.com/moona3k/macparakeet/pull/1152)
- **Replace an entire vocabulary during import.** Preview the replacement before confirming. It replaces manual words and snippets while keeping unmatched learned recognition terms. Add new entries and Replace duplicates remain available. [#1067](https://github.com/moona3k/macparakeet/pull/1067)

## Bundled CLI 4.9.0

The bundled CLI advances from 4.4.0 to 4.9.0. It adds saved AI-result editing with conflict detection, reversible batches of transcript corrections, and shared cleanup/analysis AI settings. Retry failed dictations with `retranscribe --kind dictation --update`.

Existing commands remain available. Scripts reading dictation history should handle the new `status: "error"` value. See the [CLI changelog](https://github.com/moona3k/macparakeet/blob/v0.8.8/Sources/CLI/CHANGELOG.md) for command and compatibility details. The standalone Homebrew CLI has its own release channel.

## Requirements and availability

Requires **Apple Silicon and macOS 14.2 or later**. Apple Intelligence additionally requires macOS 26+ and enabled system models on an eligible Mac.

Cross-recording Ask, Jev Voice Control, voice profiles, encrypted share links, and in-process MLX remain experimental and disabled in normal release builds.

To update, choose **Check for Updates…** in MacParakeet, or download `MacParakeet.dmg` and drag the app to Applications.

[All changes since 0.8.7](https://github.com/moona3k/macparakeet/compare/v0.8.7...v0.8.8)
