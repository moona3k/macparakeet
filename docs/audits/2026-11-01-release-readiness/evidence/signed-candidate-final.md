# Updated signed candidate after fresh review — 2026-11-01

- App **0.8.11**, build **20261101201053**; bundled CLI **5.2.0**.
- Executable source: `0146098b013e02d9e684d84163a08f541298e5d3`, including merged PR #1309, first-review fixes and fresh-review calendar/generic-year fixes. Later documentation changes do not alter executable source.
- Canonical Release/arm64 Xcode app and SwiftPM CLI builds succeeded. Minimum macOS: 14.2. Existing compiler warnings remain.
- Real FFmpeg 9.0.2, yt-dlp 2026.08.19 and pinned LocalVQE assets were supplied from the installed stable app. The canonical build packaged Node 24.13.1 and the Ask helper and checked portability, Sparkle trust anchor and echo asset identity.
- Developer ID signing succeeded with `SKIP_NOTARIZE=1 REQUIRE_MEETING_ECHO_ASSETS=1 scripts/dist/sign_notarize.sh`. Strict deep signatures, privacy surface, echo model hash, runtime deployment target and echo library signature passed.
- dSYM UUID: `4BE8F0CE-1DFD-3D57-9C62-8E84BC6A4AF0`, retained at `dist/MacParakeet.dSYM`.
- The initial build and its ZIP/dSYM are retained separately under `dist/initial-20261101185026/`. Its [receipt](signed-candidate.md) is historical evidence, not qualification of this build.
- **No notarization submission, DMG, native GUI launch, physical capture, installation, Gatekeeper acceptance, Sparkle upgrade or publication is claimed.**

## Artifact identity

Post-signing qualification passed: bundled executable version probes and CLI JSON contract; packaged Markdown colors/icons; Ask remains disabled with and without developer opt-in; independent-process persistence; real Parakeet v3 transcription of synthetic speech, fresh-process history and Markdown export in a disposable database. Strict deep signature verification passed again after execution. Raw logs use the `fresh-release-*` and `fresh-signed-helper-smoke.log` names; synthetic model evidence is under `evidence/smoke/fresh-release/`.

Hashes cover the signed, unstapled local artifacts. Stapling or rebuilding changes bytes and requires a new identity receipt.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `dist/MacParakeet.app.zip` | 170824159 | `876dd6be3385bb149521122474541705dc384efa15023e1eaa5bc6364a19bef3` |
| `dist/MacParakeet.app/Contents/MacOS/MacParakeet` | 149727488 | `b10bbce9ba40ef9aa65521482edb0d4fe820246d711bca05996c8ea27464f429` |
| `dist/MacParakeet.app/Contents/MacOS/macparakeet-cli` | 61238000 | `b14599f3fdcca925185a110aeb17364c2c8f97dcf83699f588e279c9160f62cd` |
| `dist/MacParakeet.app/Contents/Resources/ffmpeg` | 65947344 | `f177c4f2932e01fa15c21572f73b057e086b4b153a68a1e184975fffc6c054f1` |
| `dist/MacParakeet.app/Contents/Resources/yt-dlp` | 36931376 | `6af5bf61d9f19a37533ba8ee2c397a401c5d87c6508211fecbf017c7ebadfbc3` |
| `dist/MacParakeet.app/Contents/Resources/node` | 118434480 | `8e54b0e1197a29196826cef4088a4727e3b9b7a0a126e2cc01c243e90ba64cc2` |
