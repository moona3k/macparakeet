# Signed package verification for 0.8.0

The local app and DMG passed the package checks below. Apple accepted both exact notarization submissions, both artifacts validate their staples, and Gatekeeper reports `Notarized Developer ID`. The app inside the DMG matches the checked bundle. This establishes package readiness for this candidate; GUI QA and release publication remain separate gates.

## Candidate and artifact identity

| Field | Observed value |
| --- | --- |
| Source candidate | `250bbe2994a4b60b4ef81ac257f0ee6bb70874d3` |
| App version / build | `0.8.0` / `20260907232424` |
| Build metadata | `2026-09-07T23:24:24Z`, source `release-080-qa-notes`, commit `250bbe2994a4` |
| Bundled CLI | `3.3.0` |
| Verification host | Apple Silicon, macOS 26.6.2 (25G83), notarytool 1.1.1 (40) |
| Read-only verification window | 2026-09-07, 23:32–23:36 UTC |

The release owner built the app through Xcode Release and rebuilt the production CLI. The [build log](evidence/package-runtime/build-distribution-notes.log) records both stages and the final metadata. The submitted ZIP, current bundle, and mounted DMG app have matching metadata. Version metadata alone is not the provenance proof: the payload comparisons below also match the actual executable bytes.

| Artifact | Size in bytes | SHA-256 |
| --- | ---: | --- |
| Submitted `MacParakeet.app.zip` | 156945557 | `e67736b71c162e05c6adb6967175a5b4cb18cb321c926fe4d3832aa4d7e523ad` |
| Final stapled `MacParakeet.dmg` | 167213899 | `17fbf6c6a2a3ed6ada8ce3f0816adae041832f27d7b3a9a2ac9e3499859bcb22` |

Both files remained unchanged during these checks. The ZIP stays at its original local path; this task recorded its identity without copying or moving it. The DMG hash was captured after the release owner stapled it and checked again after read-only mounting. See the [ZIP manifest](evidence/package-runtime/zip-manifest.json), [DMG manifest](evidence/package-runtime/dmg-manifest.json), and [cleanup record](evidence/package-runtime/dmg-cleanup.json).

## Actual package results

| Check | Result and evidence |
| --- | --- |
| Signed app and nested code | **Passed.** Deep strict signature validation; hardened runtime, Developer ID team `FYAF2ZD7RM`. [Validation](evidence/package-runtime/app-strict-signature.log), [signature metadata](evidence/package-runtime/app-signature-details.log). |
| Privacy and meeting echo assets | **Passed in the release owner's signing run.** Privacy validator succeeded; LocalVQE dylib signature and model checksum passed. Model SHA-256: `b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731`. [Signing log](evidence/package-runtime/sign-notarize-notes.log). |
| App ticket and Gatekeeper | **Passed.** Independently validated the staple and received `accepted`, source `Notarized Developer ID`. [Staple](evidence/package-runtime/app-staple-validation.log), [Gatekeeper](evidence/package-runtime/app-gatekeeper.log). |
| DMG signature, ticket, and Gatekeeper | **Passed.** Strict signature, staple validation, and open assessment all exited 0. [Signature](evidence/package-runtime/dmg-strict-signature.log), [staple](evidence/package-runtime/dmg-staple-validation.log), [Gatekeeper](evidence/package-runtime/dmg-gatekeeper.log). |
| Disk-image integrity | **Passed.** `hdiutil verify` completed successfully. [Log](evidence/package-runtime/dmg-image-verification.log). |
| Embedded app | **Passed.** Mounted with `-readonly -nobrowse`; every Info.plist field and eight payload hashes match the current bundle. Those payloads also match the submitted ZIP: app, CLI, FFmpeg, yt-dlp, Node, Sparkle, LocalVQE dylib, and echo model. Embedded app strict signature and staple validate. [Payload comparison](evidence/package-runtime/dmg-payload-verification.json), [signature](evidence/package-runtime/mounted-app-strict-signature.log), [staple](evidence/package-runtime/mounted-app-staple-validation.log). |
| Installation structure | **Passed.** `Applications` points to `/Applications`. Sparkle's root is a real directory; internal version links remain relative. See the payload comparison above. |
| Binary dependencies | **Passed for the six inspected app/CLI/helper/dylib binaries.** All 155 dependency entries use system or bundle-relative paths; no Homebrew/build-machine dependency was found. [Dependencies](evidence/package-runtime/binary-dependencies.log), [assertions](evidence/package-runtime/runtime-metadata.json). |

The actual signed helpers ran successfully without audio capture, app activation, or downloading media:

| Invocation | Version | Exit |
| --- | --- | ---: |
| Bundled CLI `--version` | `3.3.0` | 0 |
| FFmpeg `-nostdin -version` | `9.0.1` | 0 |
| yt-dlp `--ignore-config --no-cache-dir --version` | `2026.08.19` | 0 |
| Node `--version` | `v24.13.1` | 0 |

yt-dlp took 8.02 seconds and produced no PyInstaller library-loading failure. These checks establish signed helper startup, not a complete YouTube download or transcription workflow. Exact arguments, elapsed times, and individual logs are listed in [runtime results](evidence/package-runtime/results.json).

## Notarization and continuation

| Artifact | Exact submission ID | Created UTC | Independently confirmed |
| --- | --- | --- | --- |
| App ZIP | `52abbad6-6f63-49a6-a3de-4fd7f7ba2cb3` | 23:28:55.173 | **Accepted**, query at 23:33:50 UTC |
| DMG | `faa10966-3c5d-41e1-990f-bf2f9bafa45f` | 23:30:22.395 | **Accepted**, query at 23:33:51 UTC |

The [app response](evidence/package-runtime/app-notary-info.log) and [DMG response](evidence/package-runtime/dmg-notary-info.log) are terminal Apple results. The signing log first recorded pending statuses, then app acceptance/stapling and a successful DMG upload. Its local process was stopped while the DMG was pending; Apple completed the submission independently. The release owner then stapled the accepted DMG. No new submission was created by this verification task, and no further polling is needed for these accepted IDs.

The earlier `3827999d` candidate and submission `933ba8fc-4688-42f0-9776-5e24e393c7cf` are historical. Their status does not determine acceptance of this candidate. [Distribution guidance](../../distribution.md) now describes exact-artifact continuation after a local tool failure or delayed response.

## Methodology and limitations

Read-only commands used 60-second per-process bounds. Helper checks disabled telemetry, supplied an isolated `CFFIXED_USER_HOME`, ignored yt-dlp configuration/cache, and removed inherited `NODE_OPTIONS`. No product builds, test suites, signing, uploads, microphone/system-audio actions, or desktop input ran in this subtask. The separately owned release script performed the signing, uploads, app stapling, and original Finder DMG layout; the release owner completed DMG stapling.

The first inspection harness successfully mounted and detached the DMG, but its path assertion failed because macOS returned `/private/tmp` for an input under `/tmp`. Comparing canonical paths fixed the harness. Only mount/payload inspection was repeated; the first attempt's [command results](evidence/package-runtime/dmg-results.json) remain alongside the [completed inspection](evidence/package-runtime/dmg-mount-canonical-results.json). Both owned mount directories were removed, and the DMG checksum was unchanged. This was a verification harness error, not an app failure.

The initial report that the signing script had stopped before DMG creation was stale when this task began. Reading the current log and querying the exact IDs resolved that discrepancy; process termination was not treated as Apple cancellation or as proof of the last completed stage.

This run did not install or launch the app from the DMG, validate a second physical Mac, exercise Sparkle updating, or publish a download/appcast/GitHub asset. The root QA report owns the GUI/runtime verdict and remaining release boundaries. Before publication, preserve the final stapled DMG bytes when producing the Sparkle signature and matching download metadata.

All curated files are local, sanitized evidence. `<REPO>` denotes the owning checkout and `<QA>` its temporary QA directory; the local Mac hardware identifier is redacted. The [artifact manifest](evidence/package-runtime/artifact-manifest.json) records every evidence file's checksum.
