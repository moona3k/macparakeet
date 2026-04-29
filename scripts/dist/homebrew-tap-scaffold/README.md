# `moona3k/homebrew-tap` README scaffold

This is the README that will live in the **`moona3k/homebrew-tap`** repo
(to be created). It's drafted here in the macparakeet repo so it stays
under version control and can be reviewed before the tap repo exists.

When the tap repo is cut (see `HOWTO.md`), copy this file there as the
top-level `README.md`.

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
**For AI-agent integration:** [`integrations/README.md`](https://github.com/moona3k/macparakeet/tree/main/integrations)
**Standalone-install positioning:** <https://macparakeet.com/agents>

## License

The formulae in this tap are MIT-licensed. The packages they install
have their own licenses (`macparakeet-cli` is GPL-3.0, see source).
