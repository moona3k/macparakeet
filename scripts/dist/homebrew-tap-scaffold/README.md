# `moona3k/homebrew-tap` README reference

This is the macparakeet repo's reference copy of the live
**`moona3k/homebrew-tap`** README. The actual tap lives at
<https://github.com/moona3k/homebrew-tap>.

Keep this file in sync when the tap README changes. See `HOWTO.md` for the
CLI release flow and tap update checklist.

---

# moona3k/homebrew-tap

Homebrew tap for [moona3k](https://github.com/moona3k) packages.

## Available formulae

### `macparakeet-cli`

Local Parakeet TDT speech-to-text + transcription tooling for Apple
Silicon. ~155&times; realtime on the Apple Neural Engine, ~2.5% WER,
GPL-3.0.

```bash
brew tap moona3k/tap
brew install macparakeet-cli

macparakeet-cli --version
macparakeet-cli health --json
macparakeet-cli transcribe ~/Downloads/audio.mp3 --format json
```

**Requirements:** macOS 14.2+ (Sonoma) on Apple Silicon (M1, M2, M3, M4).

**First run downloads ~6&nbsp;GB of CoreML speech models** to
`~/Library/Application Support/MacParakeet/models/`. Subsequent runs are
fully offline.

**Source code:** <https://github.com/moona3k/macparakeet>
**Compatibility policy (semver):** [`Sources/CLI/CHANGELOG.md`](https://github.com/moona3k/macparakeet/blob/main/Sources/CLI/CHANGELOG.md)
**Agent integration docs:** [`integrations/README.md`](https://github.com/moona3k/macparakeet/tree/main/integrations)
**For agent operators:** <https://macparakeet.com/agents>

## Available casks

### `macparakeet`

The full MacParakeet macOS app — system-wide dictation, file
transcription, and meeting recording. The same DMG distributed at
<https://macparakeet.com>, but installable via brew.

```bash
brew tap moona3k/tap
brew install --cask macparakeet
```

**Requirements:** macOS 14.2+ on Apple Silicon. The app self-updates
via Sparkle (`auto_updates true` in the cask), so brew won't fight
with in-app updates after install.

## License

The formulae and casks in this tap are MIT-licensed. The packages they
install have their own licenses (`macparakeet-cli` and `macparakeet` are
both GPL-3.0 — see source).
