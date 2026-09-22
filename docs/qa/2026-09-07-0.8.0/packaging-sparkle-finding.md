# Sparkle framework packaging fix and notarization status

Current status: the `cp -RH` fix is applied at `3827999ddb84c8a8e0edcb3ac190e66813fc95fe`. Root rebuilt and signed the actual app; whole-app strict signature verification, the privacy-surface check, and signed LocalVQE asset verification passed. App notarization remains pending. This is not a release-ready verdict.

The initial independent diagnosis inspected `afa6fb3db30685fe1fe3e374e02093ec117184f4` and did not modify production scripts or the actual artifact. The proposal, standalone fixture, and evidence are in `/tmp/macparakeet-080-qa/sparkle-packaging/`.

## Current notarization checkpoint

Root's signed-bundle log records the app as valid on disk, a verified privacy surface, and verified LocalVQE signatures/model checksum. The upload ZIP is 156,749,432 bytes, SHA-256 `4c9a6521c7d9d754c5a2a0f6c6d09631c598dbd5256500a8214897df6823ef02`.

Apple registered app submission `933ba8fc-4688-42f0-9776-5e24e393c7cf` at `2026-09-07T23:06:20.092Z`. Root observed `notarytool submit` terminate with SIGBUS/exit 138 despite the registered upload. Independent `notarytool info` calls succeeded and still reported **In Progress** at `2026-09-07T23:17:17Z`. This does not mean notarization was accepted.

The investigator is polling that exact ID at 60-second intervals. No replacement submission, signing, stapling, DMG construction, or desktop manipulation has been performed by the investigator. The current script has no resume flag; rerunning it would repeat signing and upload. A continuation recipe is saved locally at `/tmp/macparakeet-080-qa/sparkle-packaging/notary-resume.md`: require the existing app submission to be Accepted, staple/validate/assess that app, then create and sign a DMG and submit that distinct artifact once. A direct compressed-image route can avoid Finder automation while root's GUI QA remains active.

## Confirmed failure

At the original inspected commit, `scripts/dist/build_app_bundle.sh:561` used:

```sh
cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/"
```

The preferred Xcode source, `Release/PackageFrameworks/Sparkle.framework`, is itself an absolute symlink to `Release/Sparkle.framework`. macOS `cp -R` preserves a command-line symlink by default. Consequently, the original `dist/MacParakeet.app/Contents/Frameworks/Sparkle.framework` remained an absolute symlink into `.build/xcode-dev/Build/Products/Release/` instead of containing the framework.

Independent read-only verification reproduced the packaging failure:

```text
codesign --verify --deep --strict --verbose=2 dist/MacParakeet.app
exit 1
invalid destination for symbolic link in bundle
file modified: …/Contents/Frameworks/Sparkle.framework
```

This was a release blocker: the original bundle depended on a development-machine path and failed the existing strict gate in `scripts/dist/sign_notarize.sh:168`. No launch on another machine or notarization submission was performed during the initial independent diagnosis.

## Minimal proposed patch

```diff
-  cp -R "$SPARKLE_FW" "$FRAMEWORKS_DIR/"
+  # Follow Xcode's product symlink while preserving relative links inside the framework.
+  cp -RH "$SPARKLE_FW" "$FRAMEWORKS_DIR/"
```

The installed macOS `cp(1)` manual documents `-H` as following symlinks supplied on the command line while preserving symlinks encountered inside the copied tree. This directly addresses Xcode's product link and retains the normal versioned framework structure. It also works when the fallback source is already a real directory. The proposal does not change source selection, signing, entitlements, rpaths, or other bundle assets.

The patch is saved as `sparkle-root-symlink.patch`; a proposed full script is saved as `build_app_bundle.proposed.sh`. `git apply --check` succeeded against the inspected checkout, and `bash -n` accepted the proposed script. Neither command applied or executed the packaging script.

## Deterministic standalone reproduction

`repro.sh` creates a new temporary directory under its own location. It builds a synthetic versioned framework with an executable payload, resource/header files, four internal relative symlinks, and an external absolute product symlink. Paths include spaces. It never opens devices or invokes a build/signing operation.

| Check | Observed result |
|---|---|
| Existing `cp -R` command | Copies the external root symlink; the self-contained-framework assertion fails as expected |
| Proposed `cp -RH` command | Copies a real framework directory and preserves its payload, executable mode, and four internal links |
| Real-directory fallback source | Copies correctly using the same command |
| Move the fixture's generated source products away | Old copy becomes unusable; both corrected copies remain usable |

The fixture exits `0` only when the expected RED behavior and all corrected-copy assertions occur. It retains its generated source and output folders for inspection.

## Verification with the actual framework

The real Xcode framework was also copied into the owned temporary directory using `cp -RH`. Its copied structure was:

```text
Sparkle.framework/                 real directory
  Sparkle -> Versions/Current/Sparkle
  Resources -> Versions/Current/Resources
  Headers -> Versions/Current/Headers
  Versions/Current -> B
```

`codesign --verify --deep --strict --verbose=2` on this copied framework exited `0`, including validation of its updater and XPC components. No signing was performed. The copied binary matched the original SHA-256 `c316f939ad57f1f6114737766ab0b42fd710ec4e4c5f43210496e8b7f949fc20`.

The source binary hash and the actual app's Sparkle symlink target remained unchanged. This verifies the proposed copy operation and copied framework signature; it does not certify a rebuilt, signed app bundle.

## Evidence and remaining gate

Curated text evidence is available in the temporary directory's `sanitized-artifacts/` folder. Once copied into `evidence/packaging-sparkle/` beside this report, these links resolve:

- [Actual bundle failure](evidence/packaging-sparkle/actual-bundle-red.log)
- [Actual bundle inspection](evidence/packaging-sparkle/actual-bundle-inspection.json)
- [Standalone RED/GREEN fixture output](evidence/packaging-sparkle/fixture-red-green.log)
- [Reusable fixture](evidence/packaging-sparkle/repro.sh)
- [Proposed patch](evidence/packaging-sparkle/sparkle-root-symlink.patch)
- [Copied actual framework verification](evidence/packaging-sparkle/actual-framework-copy-green.log)
- [Copied framework structure and integrity](evidence/packaging-sparkle/actual-framework-copy-result.json)

Root has applied the patch, rebuilt/repacked the app, signed the resulting bundle, and passed strict whole-app verification. Root retains ownership of notarization continuation and release publication. The full Swift suite was not rerun or consumed by this diagnosis; no product edits, actual-artifact mutations, desktop actions, or package builds/tests were performed by this investigator.
