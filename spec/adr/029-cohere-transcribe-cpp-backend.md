# ADR-029: Cohere Transcribe Backend via transcribe.cpp

> Status: ACCEPTED
> Date: 2026-07-25
> Related: ADR-001, ADR-002, ADR-007, ADR-016, ADR-021, ADR-026
> Supersedes: the FluidAudio/CoreML implementation details for Cohere in
> ADR-001 and ADR-016. It does not change Cohere's product identity.

## Context

MacParakeet already exposes Cohere Transcribe as an optional local batch
engine. Its product behavior is established: explicit model installation,
16 GB memory admission, scheduler-wide single-flight execution, record-first
dictation, final file and meeting transcription, plain text output, no live
preview, and no word timestamps.

The original implementation used FluidAudio's CoreML Cohere pipeline. This ADR
replaces that execution backend with a narrow adapter around transcribe.cpp.
It does not add another engine card, a cloud path, or automatic engine routing.

The initial upstream baseline is `handy-computer/transcribe.cpp` v0.1.3. Source
inspection found that its Cohere prompt protocol requires a language token,
uses English as the stable fallback when the caller supplies no token, and
reports `supports_language_detect=false`. Model-backed testing established that
the pinned Q5_K_M model still transcribes representative English, German,
Japanese, and Chinese speech correctly without a caller hint. The runtime does
not, however, identify which language produced the transcript. MacParakeet
requires automatic multilingual transcription without a language-selection UI.

## Decision

### Preserve the Cohere product contract

The persisted engine identifier remains `cohere`. Existing settings keys, CLI
flags, scheduler admission, meeting leases, transcript persistence, telemetry
identity, and `STTResult` shape remain compatible. Saved Cohere language values
and `--language` are retained as legacy input compatibility, but the backend
does not use them. The obsolete Cohere language picker is removed.

Cohere remains fully local and batch-only. The result contains a detected
language when the native runtime reports one or the adapter classifies the
returned text, empty word timings, engine `cohere`, and the native compute
backend as the engine variant. Parakeet, Nemotron, WhisperKit, meeting capture,
transforms, and unrelated STT paths are unchanged.

### Use a small native adapter

`CohereTranscribeEngine` continues to own MacParakeet behavior: audio
conversion, model resolution, download verification, chunking, stitching,
error mapping, and the `STTResult` contract.

`TranscribeCppCohereBackend` owns only native model and session objects. The
backend is an actor. It loads the model off `MainActor`, runs one native
transcription at a time, forwards task cancellation to the Swift wrapper,
waits for an active run to drain, then destroys the session before the model.
Engine generation checks prevent completed work from publishing after unload.

The v0.1.3 native loader has no mid-load cancellation hook. A cancelled prepare
waiter returns promptly without cancelling a load shared by other waiters.
Explicit unload or model deletion invalidates readiness, waits for the native
open to finish, and then releases the unpublished model. During transcription,
the wrapper bridges Swift cancellation to the C abort callback. Cohere polls
that callback between decoder steps, so cancellation can wait for the current
encoder or decoder operation to finish before teardown.

The app compiles an unavailable stub when no local native package is supplied.
That supports ordinary source development and deterministic unavailable-runtime
tests. Production distribution must include the pinned owned framework and is
blocked by a release verification script if the supplied package, artifact,
architecture, provenance, or notices do not match the release pins.

### Compose automatic multilingual behavior in the adapter

At load time MacParakeet validates the runtime version, commit, model
architecture, model variant, sample rate, supported language set, and timestamp
contract. The adapter always sends `language=nil`. The owned fork carries
model-backed regression tests proving that representative English, German,
Japanese, and Chinese fixtures transcribe correctly without caller hints.

Cohere has no native language-identification head, so the native
`supports_language_detect=false` capability is expected. After transcription,
the adapter uses Apple's local Natural Language framework to classify the
returned text and restricts the result to the model's official language set.
This composed adapter capability satisfies MacParakeet's automatic-language
contract without sending audio or text off device. Very short or ambiguous
transcripts may have no detected-language metadata, but their text is retained.

The unmodified v0.1.3 release artifact remains a development reference, not a
shipping fallback. MacParakeet distribution requires an owned, self-built,
arm64-only XCFramework so the exact source, architecture, licenses, and archive
checksum are under project control.

### Bound native input and stitch long audio

The engine uses the native maximum as a hard ceiling and chooses a conservative
300-second chunk size with bounded overlap. It strips duplicate overlap text
when joining adjacent chunks. If the native runtime still reports truncation,
the engine recursively splits the affected chunk until the minimum safe size,
then returns a transcription failure rather than silently dropping audio.

No word timings are synthesized. Without reliable native timings, boundary
stitching remains text based and may retain or remove a short repeated phrase
in ambiguous cases.

### Pin source, wrapper, artifact, and model

The inspected baseline pins are:

| Component | Pin |
|-----------|-----|
| Upstream | `handy-computer/transcribe.cpp` tag `v0.1.3` |
| Annotated tag object | `d503d6a239e2a290a03ab72dbd3b40460d87acb0` |
| Upstream commit | `a94e021ef658dc7c788837341a13f6acea3baf3c` |
| Swift wrapper | `0.1.3` |
| Owned fork | `DudeMeister23/transcribe.cpp` |
| Owned implementation commit | `51aa23592167cc32f8f3c5d2155d9f9937324c8d` |
| Owned release tag | `macparakeet-v0.1.3-arm64.1` |
| Owned release artifact | `TranscribeCpp-macOS-arm64-v0.1.3-macparakeet.1.xcframework.zip` |
| Owned release URL | `https://github.com/DudeMeister23/transcribe.cpp/releases/tag/macparakeet-v0.1.3-arm64.1` |
| Owned artifact SHA-256 | `caad2e1ce80801e5d0adb7e2bb9bcf8e7d1fd295657af281d8260d5dcc629350` |
| Release immutability | GitHub immutable release, Sigstore release attestation verified 2026-07-25 |
| Upstream reference XCFramework SHA-256 | `b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd` |
| Vendored ggml upstream commit | `707321c4cf6d21cb4bc831aa8b687dbf01a521ce` |
| Vendored miniz upstream commit | `d10b03cc73475af673df40f06e5cefd1d5f940d9` |
| Model repository | `handy-computer/cohere-transcribe-03-2026-gguf` |
| Model revision | `dfa4adebb64f3076b7b6b90b721275cc069cb421` |
| Model file | `cohere-transcribe-03-2026-Q5_K_M.gguf` |
| Model size | `1,770,270,208` bytes |
| Model SHA-256 | `14d02f1ad6dd77b3a60f82639879012c3adb4fe25c50a5a47a2c4c661daf1558` |

Shipping uses the self-built macOS arm64 XCFramework from the immutable owned
release. The fork commit, release tag, artifact filename, download URL, and
archive SHA-256 are pinned in Swift source and distribution metadata. GitHub's
release attestation binds the published artifact digest to the exact fork
commit. Release builds fail if the package checkout, artifact bytes, binary
architecture, vendored provenance, or retained notices differ from those pins.

The model downloads into MacParakeet Application Support, not FluidAudio's
cache. It uses a revision-scoped directory, a resumable partial file, exact size
and SHA-256 verification, and a verification marker bound to file metadata.
Interrupted downloads resume. Corrupt files and stale markers are rejected and
can be repaired through the existing model download flow.

### Retain license notices

transcribe.cpp, its Swift wrapper, ggml, and miniz are MIT licensed. The Cohere
model is Apache-2.0. The owned XCFramework archive must include the upstream,
ggml, and miniz license files exactly as retained under `LICENSES/`.
Distribution copies those notices plus
`THIRD_PARTY_LICENSES.md` and the complete Apache-2.0 license text into the
app's Legal resources before signing. The pinned model repository contains no
separate `NOTICE` file.

## Consequences

- Cohere keeps its existing user-facing identity and local-only boundary.
- Cohere becomes the one approved narrow exception to ADR-026's original
  two-runtime rule. This does not authorize more engine cards or runtimes.
- Native ownership, cancellation, and model deletion have one deterministic
  lifecycle boundary.
- Long recordings no longer depend on the native practical input maximum.
- Cancellation during a native model open or a long encoder operation is
  bounded by completion of that non-interruptible native operation.
- Cohere distribution depends on the immutable owned artifact and fails closed
  when it is missing or differs from the pinned digest.
- The historical FluidAudio baseline stays labeled as such and must not be
  presented as transcribe.cpp performance.

## Release evidence

The release prerequisite was satisfied on 2026-07-25:

1. The authorized `DudeMeister23/transcribe.cpp` implementation is pinned at
   `51aa23592167cc32f8f3c5d2155d9f9937324c8d`. It retains the v0.1.3 baseline
   history and notices and adds unhinted multilingual model-backed regression
   coverage.
2. The arm64-only macOS XCFramework was built with
   `TRANSCRIBE_XCFRAMEWORK_SLICES=macos TRANSCRIBE_MACOS_ARCHS=arm64
   scripts/ci/build_xcframework.sh`. `TRANSCRIBE_MACOS_ARCHS` is the owned fork
   addition; upstream v0.1.3 otherwise creates a universal macOS slice.
   `scripts/ci/package_xcframework.sh` preserved the three native MIT notices
   in the archive.
3. GitHub published the immutable
   `macparakeet-v0.1.3-arm64.1` release with artifact SHA-256
   `caad2e1ce80801e5d0adb7e2bb9bcf8e7d1fd295657af281d8260d5dcc629350`.
   The downloaded release asset matched the locally verified build byte for
   byte, and `gh release verify` validated GitHub's Sigstore attestation.
4. English, German, Japanese, and Chinese fixtures ran through the actual
   MacParakeet CLI. Cold load, warm transcription time, realtime factor, and
   peak RSS are recorded beside the historical CoreML baseline in
   `benchmarks/asr/results/cohere-transcribe-cpp-migration.md`.
5. Focused tests and the complete Swift suite passed as the final code gates.
