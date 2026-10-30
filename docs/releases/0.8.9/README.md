# MacParakeet 0.8.9

Published on September 27, 2026: [GitHub release](https://github.com/moona3k/macparakeet/releases/tag/v0.8.9).

- [GitHub release body](github.md): changes since 0.8.8, setup migration, and CLI compatibility, with a link to the previous release.
- [Sparkle description](sparkle.html): 0.8.9 fixes plus a short 0.8.8 recap for users skipping that release. The feed retains the previous release entries.
- [Website changelog](https://macparakeet.com/changelog/): 0.8.9 first, with 0.8.8 directly below in release history.

The signed app is built from `a89a152c84a955a6c377e918a6d0f64e637d22a2`, build `20260927172238`, and bundles CLI 5.0.0. Later documentation commits do not change the signed binaries. [PR #1190](https://github.com/moona3k/macparakeet/pull/1190) supplies the AI Setup and provider-routing fixes.

The shipped DMG is **179,954,239 bytes**, with SHA-256 `c856ff497d625a62ce8b0081ca0e0d294c3ddc75a9e8833216bc09875f108f81`. The public GitHub `MacParakeet.dmg` asset and the [versioned Sparkle enclosure](https://downloads.macparakeet.com/MacParakeet.dmg?v=20260927172238) were downloaded after publication and matched the signed local file exactly. The live appcast version, build, size, URL, and signature match this artifact.

Verification completed:

- [CI on the exact release source](https://github.com/moona3k/macparakeet/actions/runs/36336766838): tests, Swift 6, and release/bundle checks passed.
- App notarization `168d13f4-8fe4-4fc4-b700-f5b5fb5119f3` and DMG notarization `d30a71cf-5f64-460d-8b9a-f0a4f539a747` were Accepted. Signing, stapling, Gatekeeper, and DMG integrity checks passed.
- The mounted DMG contained the verified app and CLI 5.0.0. Bundled executable helpers, meeting echo assets, and Markdown resources passed their checks.
- Packaged Parakeet transcription, fresh-process database readback, and Markdown export passed using synthetic audio and an isolated database.
- Nine packaged CLI checks confirmed explicit Apple Intelligence summary, chat, and Transform requests fail before generation in plain, streaming, and JSON modes.
- Website build, release-consistency checks, and desktop/mobile changelog inspection passed. Pages and both telemetry workers were deployed with the updated published-release allowlist.

The unversioned download URL initially served cached 0.8.8 bytes even though a HEAD request showed the new object. Website download links now use the versioned URL in the shared release data; the versioned enclosure and GitHub asset were verified by full downloads, not just headers. Existing unversioned links may serve the old cached object until its cache expires.

Automated and packaged-artifact checks do not establish physical microphone/Bluetooth/macOS 27 behavior or an interactive Sparkle upgrade. Those were not exercised for this release.

Voice Control, cross-recording Ask, voice profiles, encrypted share links, and in-process MLX retain their existing release gates. Canonical current release status lives in [the spec index](../../../spec/README.md#release-channels-and-feature-flags). The standalone Homebrew CLI remains a separate release channel.
