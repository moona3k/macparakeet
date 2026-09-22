# Executed engine sample checks

Initial matrix candidate: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`; DEBUG CLI 3.3.0, binary SHA-256 `db8626c81735d0484878f396cae83c6a911a6cba9ff97d0a9ee139eb2cdcf690`.

Host: Apple M4 Pro, 48 GB RAM, macOS 26.6.2. These are sequential short public-fixture inference checks. Other local work continued, so wall time is observational rather than a controlled performance benchmark. No microphone, speaker playback, saved preference changes or personal recordings were used.

| Case | Outcome | Wall time | Timed words |
|---|---|---:|---:|
| parakeet-v3-en | Completed | 15.3 s | 28 |
| parakeet-v2-en | Completed | 15.36 s | 28 |
| parakeet-unified-en | Completed | 12.97 s | 27 |
| nemotron-en | Completed | 16.59 s | 28 |
| cohere-en | Completed | 233.54 s | 0 |
| nemotron-ko | Completed | 21.93 s | 13 |
| nemotron-ja | Completed | 1.74 s | 1 |
| nemotron-zh | Completed | 0.96 s | 3 |
| cohere-ko | Historical 240-second limit; later runtime pass below | 240.22 s | 0 |
| cohere-ja | Historical 240-second limit; later runtime pass below | 243.78 s | 0 |
| cohere-zh | Historical 240-second limit; later runtime pass below | 240.47 s | 0 |

English Parakeet v2/v3/Unified and Cohere closely match the 28-word LibriSpeech reference, allowing punctuation and hyphenation. Multilingual Nemotron renders “flour fatten” for “flour fattened.” The CJK Nemotron outputs preserve script with some recognition substitutions and spoken-number forms. No corpus WER/CER or general accuracy claim is made from one sample per language.

Cohere English completed after 233.54 seconds; logs put about 218 seconds in encoder loading. Its CJK attempts exceeded the 240-second harness bound at the same stage. A five-second process sample showed CoreML/MIL weight dequantization work, not proof of a deadlock. Each CJK sample subsequently completed an explicit 600-second-bound follow-up, resolving the missing runtime result. The original timeouts remain historical evidence; variable cold encoder loading is not resolved or certified. Cohere does not promise word timing; its successful result contains zero timed words.

Separate English Nemotron and Whisper Turbo were absent from the isolated cache and were not downloaded. macOS 14 behavior and other hardware are unverified.

The exact command arrays, fixture hashes and wall times are in [results.json](evidence/results.json). Individual result JSON and stderr files share the case name in `evidence/`. [Public fixture provenance and references](audio-review.md#public-prerecorded-fixture-inventory-observed) describe the source corpora.

Method: explicit engine/variant/language, `--mode raw --speaker-detection off --no-history --database <owned path> --format json`; per-process telemetry opt-out and isolated Foundation home. The initial runner summary looked for `text`; actual CLI output uses `rawTranscript`, which was independently inspected above. The original raw evidence is preserved.


## Explicit follow-ups for the three bounded Cohere attempts

All three follow-ups completed with exit 0 and nonempty `rawTranscript` in the
expected script. They used the copied CLI with SHA-256
`f8a62b79ece6045909d15ece2fd086eed7e10ca04ebc870d9fc50ed76774f095`, compiled
from `8548c099` plus recovery fix `c506d7ef`; this is distinct from the initial
matrix's binary and from the final distribution build. Each case had its own
600-second deadline and no-history database. Japanese ran once; after its
success, Korean then Mandarin each ran once. English was not rerun.

| Follow-up | Exit | Wall time | Raw characters | Timed words | Saved rows |
| --- | ---:| ---:| ---:| ---:| ---:|
| Japanese | 0 | 49.271 s | 46 | 0 | 0 |
| Korean | 0 | 7.896 s | 67 | 0 | 0 |
| Mandarin | 0 | 6.642 s | 26 | 0 | 0 |

Binary and fixture hashes remained unchanged. The [extended report](cohere-extended.md)
retains public hypotheses and recognition substitutions, including Japanese
`コース` → `構成` and Korean `다리 밑 수직` → `다리의 수집`. This is runtime
completion evidence, not a general accuracy pass.

The later model-load intervals were much shorter, consistent with a warmer
path, but cache state and host load were uncontrolled. All follow-ups finished
below even the original deadline. Success therefore does not prove the original
attempts would have completed simply by waiting longer, nor promise cold-load
performance. Retain the original failed attempts and link them to these explicit
successful probes; no language-specific engine failure is established.

Durable evidence: [combined validation](evidence/cohere-extended/summary.json),
[source/curated hashes and provenance](evidence/cohere-extended/manifest.json),
and [per-language outputs and logs](cohere-extended.md#durable-evidence).
