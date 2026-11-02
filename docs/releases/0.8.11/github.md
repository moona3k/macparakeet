# MacParakeet 0.8.11

Draft release notes. This candidate has not been published.

- **Start your next meeting while the previous recording finishes processing.** The microphone is released before playback preparation and transcription finish. Saved meetings show their processing state, and their detail view offers Retry when finalization fails.
- **Get a reminder to record an active meeting.** Opt-in Beta reminders can recognize supported meeting apps and browser calls. The setting starts off, and recording starts only when you choose Record.
- **Choose your dictation sounds.** Pick separate start and stop cues, adjust their volume, or import your own sounds. New Bloom and Gong cues are included.
- **Control dictation from a link.** The optional setting accepts `macparakeet://dictation/start` and `macparakeet://dictation/stop`. It starts off. Once enabled, other apps and websites can send those links.
- **More reliable keyboard interaction.** App-generated paste events are separated from physical shortcut state, and interrupted streaming insertion stops retrying after a failed flush.
- **YouTube playback supports separate video and audio streams.** Preparation shows progress. If a saved audio file is available, you can return to it by cancelling preparation or choosing Hide Video after a failed load.
- **File transcription reports scratch-storage failures.** Audio-track discovery creates its temporary folder on demand and shows the underlying error if its scratch output cannot be written or read, instead of treating the file as having no tracks.
- **Improved echo reduction in saved meeting transcripts** when system audio and microphone timing are slightly offset.
- **Knowledge cards recover from incomplete output.** Generation makes one corrective retry and preserves an existing card if replacement fails.
- **Automatic meeting titles recover from transient provider failures.** Valid topic years and longer titles within the character limit are retained. Generic labels with only a year are rejected; adopted calendar names and manually edited titles remain protected.
- **Settings and vocabulary are easier to use.** Compact windows keep controls accessible, search covers more rows, vocabulary load failures are reported, and standalone terms such as `C++`, `C#`, and `.NET` match correctly.

## Bundled CLI 5.2.0

History JSON includes saved transcript and speaker corrections. Vocabulary processing uses the corrected punctuation boundaries. `meetings show --json` can report `activity_detection` in `startContext.triggerKind`; callers with a closed list of trigger values should accept it. Processing meetings may appear before playback is prepared, with unknown duration. Existing fields and exit codes remain unchanged. The standalone Homebrew CLI has its own publication step.

Upgrading from an older version? Apple Intelligence is available for Dictation & cleanup on macOS 26 or later with system models enabled. Summaries, chat, and Transforms require another provider. If you previously selected Apple Intelligence, check Settings → AI Setup: an old Apple default is cleared, and an old Apple analysis override falls back to Default AI. Saved API keys remain.

Requires Apple Silicon and macOS 14.2 or later. Experimental Voice Control, Ask, voice profiles, encrypted sharing and in-process MLX remain gated off in Release builds.
