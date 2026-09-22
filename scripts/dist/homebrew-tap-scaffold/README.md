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

The first transcription with a local engine downloads the selected CoreML
model. Parakeet, Nemotron, and Cohere models are cached under
`~/Library/Application Support/FluidAudio/Models/`; optional Whisper models
use `~/Library/Application Support/MacParakeet/models/stt/whisper/`.
Subsequent transcription with that model is fully offline.

**Source:** <https://github.com/moona3k/macparakeet>
**Compatibility policy (semver):** [`Sources/CLI/CHANGELOG.md`](https://github.com/moona3k/macparakeet/blob/main/Sources/CLI/CHANGELOG.md)
**Agent integration docs:** [`integrations/README.md`](https://github.com/moona3k/macparakeet/tree/main/integrations)
**For agent operators:** <https://macparakeet.com/agents>

> Why a tap and not homebrew-core? `macparakeet-cli` ships as a signed,
> precompiled Apple-Silicon binary, and homebrew-core only accepts formulae
> that build from source (or produce cross-platform binaries). A tap is the
> correct permanent home for it.

## Mac app — now in the official Homebrew cask

The MacParakeet macOS app no longer ships from this tap. It graduated to the
official **[`homebrew/cask`](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/m/macparakeet.rb)**
on 2026-06-06, so no tap is required:

```bash
brew install --cask macparakeet
```

Homebrew keeps the official cask up to date automatically (BrewTestBot
autobump). Existing app installs from this tap are redirected to the official
cask automatically via [`tap_migrations.json`](tap_migrations.json) on the
next `brew update`.

## License

The formulae in this tap are MIT-licensed. The packages they install have
their own licenses (`macparakeet-cli` is GPL-3.0 — see source).
