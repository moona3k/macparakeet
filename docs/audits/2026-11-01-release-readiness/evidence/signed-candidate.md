# Local signed candidate — 2026-11-01

This is the **initial, superseded** candidate receipt. It predates the fresh-review title fixes; its successful checks do not qualify later source changes.

- App: **0.8.11**, build **20261101185026**; bundled CLI **5.2.0**.
- Executable source: `b9eab04a1f4f` (includes upstream `f7d1a4457` and review fixes through `d66cfae0f`).
- Build: canonical `scripts/dist/build_app_bundle.sh`, Release/arm64, Xcode 26.4.1, Swift 6.3.1, minimum macOS 14.2. Both Xcode app and SwiftPM CLI builds succeeded. Existing compiler warnings remain; this is not a warning-free build claim.
- Required LocalVQE runtime/model, real FFmpeg and yt-dlp seed reused from the installed stable app as explicit build inputs; the bundle script verified portability and echo asset identity. Node 24.13.1 and the Ask helper were packaged by the canonical script.
- Signing: `SKIP_NOTARIZE=1 REQUIRE_MEETING_ECHO_ASSETS=1 scripts/dist/sign_notarize.sh`. Developer ID **Daniel Moon (FYAF2ZD7RM)**, hardened runtime, nested helper entitlements, strict deep verification, privacy strings/entitlements and signed echo assets passed.
- dSYM UUID: `9E80F7CA-26F8-3A4D-A684-3C1628ADB6A6`; retained at `dist/initial-20261101185026/MacParakeet.dSYM`.
- Local app and notarization-input ZIP are retained. **No notarization submission, DMG, installation, native GUI launch, Gatekeeper acceptance, Sparkle upgrade or publication is claimed.**

## Artifact identity

These hashes describe the signed, unstapled local candidate. Stapling or rebuilding changes bytes; record new identity after final distribution qualification.

Post-signing qualification passed: CLI 5.2.0, yt-dlp 2026.08.19, FFmpeg 9.0.2 and Node 24.13.1 execute; CLI JSON contract and isolated persistence checks pass; packaged Markdown colors/icons resolve; Ask stays disabled in Release even with developer opt-in. The signed CLI performed real Parakeet v3 transcription of synthetic speech, fresh-process history retrieval and Markdown export in a disposable database. Strict deep signature verification passed again after execution. These results do not establish native GUI, physical capture, real YouTube network extraction or upgrade behavior.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `dist/initial-20261101185026/MacParakeet.app.zip` | 170819726 | `2e46e44e3428bdbd77060b094ca5360dc74db67d6a87b6a1b57de52ba3c1c163` |
| `dist/initial-20261101185026/MacParakeet.app/Contents/MacOS/MacParakeet` | 149711072 | `a8798bba5654bdb254ef3c6e1972ee1facba535c45281ad409b24666e2ee0124` |
| `dist/initial-20261101185026/MacParakeet.app/Contents/MacOS/macparakeet-cli` | 61238000 | `dfc46be9d354002650d5e244550ada32f18ed789186370b54ee7c0ee98af4740` |
| `dist/initial-20261101185026/MacParakeet.app/Contents/Resources/ffmpeg` | 65947344 | `9261f09dc2866cc2ad559484ab7941cbcae58923c98b6c299cc9917fed5cb842` |
| `dist/initial-20261101185026/MacParakeet.app/Contents/Resources/yt-dlp` | 36931376 | `043551b31a696a726aa5acdbc81dbaec05ceaad0c7a87a8716393916a2db3771` |
| `dist/initial-20261101185026/MacParakeet.app/Contents/Resources/node` | 118434480 | `49b3276b80377726a2a72c0a28d972fbcdc2c8599769a74ba91339999d635362` |
