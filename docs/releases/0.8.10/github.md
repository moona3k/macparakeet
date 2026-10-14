# MacParakeet 0.8.10

Meetings recover more reliably, transcripts are easier to correct, and long meeting cleanup uses less memory.

- **Choose the speaker count before transcribing a file or link.** While speaker detection is on, Transcribe shows Speakers: Auto. Pick 1–12 for the next drop, file, or link, including every file in that batch. The choice resets to Auto afterward. A video already in the Library is transcribed again so the count applies. Meetings still use Re-transcribe for an exact count.
- **Short replies stay with the speaker who said them.** One-word turns such as “Yeah”, “Okay”, and “Yes” are no longer folded into a neighbor. Exact counts also handle long stretches of silence better, so a muted track is less likely to become extra speakers.
- **Unclaimed words are not another person.** In a diarized meeting, system-track words that no speaker claimed are labelled Unattributed, listed last, and left out of the speaker count. Re-transcribe an older meeting to see the new label. A meeting with speaker detection off still says Others.
- **Search a transcript and replace the words.** In a timed transcript, ⌘F opens find and ⌥⌘F opens find with replace. Replace changes the current match; Replace All changes every match. Each replacement is one undoable edit. Transcripts without timing still use the whole-transcript editor.
- **A meeting microphone that fails to start is retried.** If the microphone or system audio never arrives, the recording says so instead of continuing quietly. Switching audio devices while you are not recording no longer leaves the shared microphone stuck.
- **Long meetings use less memory while they are running and while they are cleaned up.** Live preview no longer holds the capture stream. If preview falls behind, some live words may skip, and the saved recording is kept. Cleaned-mic processing no longer holds the whole recording in memory. A one-hour synthetic render dropped from about 988 MiB to about 26 MiB of peak footprint. Raw audio is unchanged.
- **Add a second dictation shortcut.** Settings → Capture → Dictation → Additional shortcuts can keep Fn on the Mac keyboard and another key on an external keyboard active together. Both pairs start off until you set them. A modifier chord matches exactly: ⌘D no longer also starts dictation for ⇧⌘D, and the extra modifier still reaches the front app.
- **Control a recording from a link, if you turn it on.** Settings → Capture → Allow recording control from links accepts `macparakeet://meeting/start`, `pause`, `resume`, and `stop`. It is off until you enable it. Once enabled, other apps and websites can send those links.
- **New libraries include meeting notes in Summary.** Libraries you already have keep their current Summary setting. Turn notes off per prompt if you do not want them.
- **Claude model lists match the current lineup,** including Sonnet 5.5. Saved API keys stay put. Ordinary startup and settings checks no longer open Keychain password dialogs. If macOS blocks access to a saved key, AI Setup says how to allow it; the key is not removed.
- **Stopping a transcription stays stopped.** Cancelling during speaker detection or formatting no longer saves that run as a finished transcript. Deleting many Library rows no longer brings a deleted row back when the page refreshes.
- **Long transcripts finish cleanup.** AI cleanup no longer fails at 30 seconds. A long recording is cleaned in sections of at most 12,000 characters and joined.

**If you use Anthropic or OpenRouter from the command line:** a command that omits `--model` now uses Claude Sonnet 5.5. Pass `--model` to keep an older id.

Requires **Apple Silicon and macOS 14.2 or later**. Update with **Check for Updates…**, or download `MacParakeet.dmg` and drag it to Applications.

Coming from 0.8.8 or earlier? This update also includes [everything in 0.8.9](https://github.com/moona3k/macparakeet/releases/tag/v0.8.9): saved API keys stay when AI is turned off, Apple Intelligence is for cleanup only, and AI Setup shows which provider each task will use.

[Changes since 0.8.9](https://github.com/moona3k/macparakeet/compare/v0.8.9...v0.8.10)

## Bundled CLI 5.1.0

The app bundles CLI 5.1.0. Omitting `--model` on inline Anthropic and OpenRouter commands selects Claude Sonnet 5.5 (`claude-sonnet-5-5` or `anthropic/claude-sonnet-5.5`). Explicit speaker-count transcription no longer over-splits digital silence. In a diarized meeting, unclaimed system-track words are labelled Unattributed and left out of `speakerCount`. Newly seeded Summary prompts include meeting notes; existing prompt settings are preserved. Keychain reads during CLI commands no longer open a password dialog. `retranscribe --update` returns the row the shared transcription service committed, so a concurrent edit or deletion is not overwritten. This build also waits 300 seconds for a non-streaming cloud response and cleans a long transcript in sections of at most 12,000 characters. See the [CLI changelog](https://github.com/moona3k/macparakeet/blob/v0.8.10/Sources/CLI/CHANGELOG.md). The standalone Homebrew CLI has a separate release channel.
