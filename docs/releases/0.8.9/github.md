# MacParakeet 0.8.9

A small follow-up to 0.8.8 that makes AI setup clearer and fixes saved-key handling.

- **Keep saved API keys when turning AI off.** Clear and None keep your saved keys. Use Remove saved key to delete a key that no saved route uses. Unsaved key edits survive switching providers and are discarded when all AI is turned off.
- **Use Apple Intelligence just for cleanup.** Set Default AI to None and choose Apple Intelligence under Dictation & cleanup. It no longer appears for summaries, chat, or Transforms, where its small context window could cause failures. Eligible Macs still need macOS 26+ and Apple Intelligence enabled in System Settings.
- **See what each task will use.** AI Setup names inherited providers and shows which tasks are configured or off. Prompt settings use the provider assigned to that task, including Transforms.

**If you selected Apple Intelligence in 0.8.8:** check Settings → AI Setup after updating. An old Apple default is cleared; an old Apple analysis override falls back to Default AI. Saved API keys remain. Select Apple Intelligence under Dictation & cleanup to keep using it there.

## Bundled CLI 5.0.0

Explicit Apple Intelligence requests for summaries, chat, and Transforms now fail before generation, including streaming requests. Scripts using those commands must select another provider. Apple Intelligence remains available for the cleanup route. See the [CLI changelog](https://github.com/moona3k/macparakeet/blob/v0.8.9/Sources/CLI/CHANGELOG.md) for compatibility details. The standalone Homebrew CLI has a separate release channel.

Requires **Apple Silicon and macOS 14.2 or later**. Update with **Check for Updates…**, or download `MacParakeet.dmg` and drag it to Applications.

Coming from 0.8.7 or earlier? This update also includes [everything in 0.8.8](https://github.com/moona3k/macparakeet/releases/tag/v0.8.8): failed-dictation retry, transcript and saved-result editing, a faster Library, and updated speech-model options.

[Changes since 0.8.8](https://github.com/moona3k/macparakeet/compare/v0.8.8...v0.8.9) · [Fix details: #1190](https://github.com/moona3k/macparakeet/pull/1190)
