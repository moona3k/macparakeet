# Distribution script preflight for 0.8.0

All **24 command invocations passed their expected outcomes**. This is script and synthetic-fixture evidence; it does not establish that a particular app or DMG is signed, notarized, portable, or release-ready.

## Provenance and method

- Checkout: `/Users/dmoon/code/macparakeet-qa`.
- Source HEAD: `df98cfbd41a150f8ee510dd1333bfa6db176e342`. The checked scripts matched HEAD after the run. Other agents' ongoing source and documentation edits were preserved.
- First command started: `2026-09-07T22:39:33.605556+00:00`.
- Environment: macOS 26.6.2 (25G83), Python 3.14.6, system Bash and Apple command-line tools.
- Each command received an owned `TMPDIR` under `/tmp/macparakeet-080-qa/package-preflight/tmp/`, plus `MACPARAKEET_TELEMETRY=0`. The development-version signing override was removed from the test environment.
- The root agent explicitly permitted standalone `swiftc` helper fixtures. No SwiftPM/Xcode product build or test suite ran here. No signing, notarization, publication, production app quit, audio capture, desktop input, or app activation occurred.
- The AppKit suite launches only its own accessory apps without windows, activation, or dialogs. Its exact executable paths stay inside its temporary ownership root. The pure helper suite terminates only its own copied `sleep` and shell children.

The reusable local runner is `/tmp/macparakeet-080-qa/package-preflight/run_preflight.py`. Run it with:

```sh
python3 /tmp/macparakeet-080-qa/package-preflight/run_preflight.py
```

The runner overwrites its own logs and fixtures when rerun. Save the current evidence first if retaining multiple runs.

## Results

| Check | Exact command or command family | Observed result |
| --- | --- | --- |
| Shell syntax | `bash -n <script>` for all nine `scripts/dist/*.sh` files and the three shutdown shell scripts | 12 commands, exit 0 each |
| App entitlement plist | `plutil -lint scripts/dist/MacParakeet.entitlements` | Exit 0 |
| Privacy validator fixtures | `bash scripts/dist/test_verify_app_privacy_surface.sh` | Exit 0; 11 fixtures: 2 accepted, 9 rejected |
| Release-version fixtures | `bash scripts/dist/test_verify_release_version.sh` | Exit 0; 10 fixtures: 2 accepted, 8 rejected |
| Shutdown helper and wrapper | `bash scripts/dev/test_stop_app_processes.sh` | Exit 0; all 8 PASS groups; 7.139 seconds |
| AppKit shutdown fixtures | `bash scripts/dev/test_stop_app_processes_appkit.sh` | Exit 0; all 6 PASS groups; 73.248 seconds |
| Echo-asset early guards | `bash scripts/dist/verify_meeting_echo_assets.sh <owned synthetic app>` | 7 commands: optional absence accepted; 6 required/invalid cases rejected |

The privacy suite stubs `codesign` and uses real plist/Python validation. It proves the approved ATS shape passes and missing, widened, or over-permissive ATS shapes fail. It does **not** verify a real signing identity or cryptographic signature. The version suite rejects `0.0.0`, `dev`, `pdx`, missing/empty versions, and malformed semver.

The shutdown suites verify literal path matching, argument-only decoys, invalid arguments, normal delayed exit, refused/cancelled quit, raw executables without an app-quit interface, compiler failure, argument/status preservation, and wrapper cleanup. AppKit additionally exercises real ordinary quit with deferred finalization, symlink and outside-root rejection, cancellation, and unfinished finalization. Expected `Build aborted` diagnostics are successful refusal assertions.

The AppKit assertions completed before its deliberately unfinished termination fixture exited. Its built-in 60-second lifetime bound accounts for the longer total duration; a cleanup observation found only that owned fixture still running partway through. Final checks found **zero remaining owned fixture processes** and **zero AppKit fixture directories**. The test's temporary compiler module caches remain local under the owned output directory.

The echo probes are additional local harness cases, not an existing checked-in test suite. They use empty bundles or explicitly invalid text placeholders. The six expected exit-1 cases are required assets absent, library-only, model-only, multiple GGUF filenames, a model name containing a path, and a non-Mach-O library. No real LocalVQE model or dylib was validated.

## Evidence

All paths below are local, synthetic evidence:

- [Runner output](/tmp/macparakeet-080-qa/package-preflight/runner.log)
- [Exact argument vectors, environment overrides, statuses, timings, and raw-log paths](/tmp/macparakeet-080-qa/package-preflight/results.json)
- [Source SHA256 inventory and tool/platform metadata](/tmp/macparakeet-080-qa/package-preflight/metadata.json)
- [Cleanup evidence](/tmp/macparakeet-080-qa/package-preflight/cleanup.json)
- [Shutdown helper raw log](/tmp/macparakeet-080-qa/package-preflight/logs/stop-app-processes-fixtures.log)
- [AppKit fixture raw log](/tmp/macparakeet-080-qa/package-preflight/logs/stop-app-appkit-fixtures.log)
- [Privacy fixture raw log](/tmp/macparakeet-080-qa/package-preflight/logs/privacy-fixtures.log)
- [Version fixture raw log](/tmp/macparakeet-080-qa/package-preflight/logs/release-version-fixtures.log)

## Actual artifact checks still owned by the release run

The governing instructions are [distribution.md](../../../docs/distribution.md). Source inspection of [build_app_bundle.sh](../../../scripts/dist/build_app_bundle.sh), [sign_notarize.sh](../../../scripts/dist/sign_notarize.sh), and the three validators identifies these remaining checks:

1. **Provenance and version:** build from the final verified source. Check `CFBundleShortVersionString` is exactly `0.8.0`, `CFBundleVersion` is the intended increasing build number, `MacParakeetGitCommit` matches that source, and the bundled CLI reports `4.0.0`, the major bump recorded in [Sources/CLI/CHANGELOG.md](../../../Sources/CLI/CHANGELOG.md) for the breaking `export --stdout --format txt` behavior. `verify_release_version.sh` checks release-shaped metadata, not that it equals the intended release or exceeds the prior build. With `SKIP_BUILD=1`, the builder can stamp current metadata onto reused binaries, so metadata alone is not proof of binary provenance.
2. **Bundle portability:** confirm the Apple Silicon app/CLI, compiled resource bundles/assets, icon, legal notices, Sparkle framework, and `@executable_path/../Frameworks` rpath. Inspect actual binary dependencies; exercise the packaged FFmpeg, yt-dlp, and Node helpers. The distribution guide specifically requires `yt-dlp --version` after signing because its embedded Python runtime can fail despite successful signature verification. Runtime resource lookup needs the packaged app smoke owned by root.
3. **Meeting echo assets:** run `REQUIRE_MEETING_ECHO_ASSETS=1 scripts/dist/verify_meeting_echo_assets.sh "$QA_APP"`. This requires the paired executable Mach-O library and exactly one model, required LocalVQE symbols, the expected model checksum, and portable dylib references. For a custom model, supply its expected checksum. The script defaults to allowing no assets unless required mode is set.
4. **Signed app:** after signing, run the commands below against the final bundle. The privacy check verifies required permission strings/entitlements, signing identity, and the ATS allowlist. Inspect the actual entitlement dump when reviewing the complete signed surface.
5. **Notarized deliverable:** validate the app and DMG staples and Gatekeeper acceptance only after notarization. Run the packaged CLI's local transcription/export smoke and root's GUI checks. Later publication must retain the same final DMG bytes across the upload, Sparkle signature, appcast length, and GitHub asset; no publication check was performed here.

```sh
# QA_APP is the final release candidate bundle path.
scripts/dist/verify_release_version.sh "$QA_APP"
plutil -p "$QA_APP/Contents/Info.plist"
"$QA_APP/Contents/MacOS/macparakeet-cli" --version
codesign --verify --deep --strict --verbose=2 "$QA_APP"
scripts/dist/verify_app_privacy_surface.sh "$QA_APP"
REQUIRE_MEETING_ECHO_ASSETS=1 VERIFY_CODE_SIGNATURES=1   scripts/dist/verify_meeting_echo_assets.sh "$QA_APP"
xcrun stapler validate "$QA_APP"
spctl --assess --type execute --verbose=4 "$QA_APP"
"$QA_APP/Contents/Resources/yt-dlp" --version
```

Before rebuilding a candidate, account for `build_app_bundle.sh` removing `dist/$APP_NAME.app` near the start (line 76). That script does not invoke the dev shutdown helper. Replacing a running candidate is outside this preflight and should be avoided by the release owner.

No product defect was found by these checks. The synthetic suites passed; the actual final artifact checks above remain separate release evidence.
