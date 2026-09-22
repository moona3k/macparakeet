# Extended Cohere language probes

Status: **RUNTIME PASS for all three follow-up samples**. Japanese, Korean and
Mandarin each completed one sequential probe with a 600-second bound. No probe
reached its deadline. These results establish sample completion and script
preservation, not general language accuracy or predictable cold-load latency.
The original 240-second timeout evidence remains unchanged.

## Provenance and isolation

- Copied CLI: `<QA_ROOT>/macparakeet-cli-runtime`, SHA-256
  `f8a62b79ece6045909d15ece2fd086eed7e10ca04ebc870d9fc50ed76774f095`.
- Compiled source supplied by root: `8548c099af5ee2ab0ed4dd9efe757d85c498cca0`
  plus recovery fix `c506d7ef7d4cf98f3986cfb5de84ced6b4ce701e`. This is the
  copied runtime CLI, not the newly built final distribution artifact.
- Public FLEURS files came from `<PUBLIC_FLEURS>/`.
  Binary and input hashes were checked before and after every invocation and
  remained unchanged.
- `CFFIXED_USER_HOME=<QA_ROOT>/isolated-home` reused the prepared
  model cache. `MACPARAKEET_TELEMETRY=0`, `DO_NOT_TRACK=1`, and an owned `TMPDIR`
  were set; any inherited `MACPARAKEET_DEBUG_APP_STATE_DIR` was removed.
- Each case used its own database, explicit language, raw processing,
  speaker detection off and no history. All three owned databases contain zero
  transcription rows. No provider settings, keys, source media, audio devices,
  GUI state, Swift builds or test suites were changed by this subtask.

| Language / fixture | Input SHA-256 |
| --- | --- |
| Japanese `ja_jp/ja_jp_0000.wav` | `26b6cd491b5d52cf05d89207cb88499cdaba89749aebc29c8f216e834e3d9071` |
| Korean `ko_kr/ko_kr_0000.wav` | `b1f6cf6dde1647ea71e564d0e3efd4bbeb573674dec13f977625fd94ca1b5147` |
| Mandarin `cmn_hans_cn/cmn_hans_cn_0000.wav` | `5214e16584b6498ddbd22f321738c0f62b19117ab1880b21e405fba983986b6a` |

## Observed results

| Case | UTC interval, 2026-09-07 | Exit | Wall time | Media duration | Raw characters | Result |
| --- | --- | ---:| ---:| ---:| ---:| --- |
| Japanese | 23:02:25–23:03:14 | 0 | 49.271 s | 10.440 s | 46 | Completed; Japanese script |
| Korean | 23:05:28–23:05:36 | 0 | 7.896 s | 12.480 s | 67 | Completed; Hangul |
| Mandarin | 23:05:36–23:05:42 | 0 | 6.642 s | 10.380 s | 26 | Completed; Han characters |

Every JSON output reports `status: completed`, `engine: cohere`,
`engineVariant: ane`, and the requested language. All have zero word timestamps,
which is expected for this Cohere surface. Validation reads the actual
`rawTranscript` field; it does not mistake an absent `text` field for an empty
transcript. Rechecked output hashes, exit status, engine/language fields, script,
media duration and no-history row counts are retained in `summary.json`.

Japanese:

```text
インターネットで敵対的環境構成について検索すると、おそらく現地企業の住所が出てくるでしょう。
```

Korean:

```text
다리의 수집 간격은 15미터이며 공사는 2011년 8월에 마무리되었으며 해당 다리의 통행 금지는 2017년 3월까지이다.
```

Mandarin:

```text
这并不是告别:这是一个篇章的结束,也是新篇章的开始。
```

The Japanese reference uses `コース` where the hypothesis uses `構成`; the
Korean reference starts `다리 밑 수직 간격은` where the hypothesis starts
`다리의 수집 간격은`. These substitutions are retained explicitly. No WER/CER,
accuracy threshold, speaker/timing quality or corpus-wide conclusion was tested.

## Method and interpretation

Root first authorized one longer Japanese probe because earlier attempts had
stopped at the harness's 240-second bound during encoder loading, with active
CoreML work observed. After Japanese completed, root explicitly authorized one
Korean and one Mandarin follow-up. Japanese and English were not rerun. Root
reserved real inference for these sequential commands; other GUI fixture work
could continue. Real-inference ownership was released after the last child exited.

The runners use `subprocess.run(..., timeout=600)` and retain raw stdout/stderr.
On timeout, that API kills and waits for only its owned CLI child; no timeout
cleanup was needed here. The runners refuse to overwrite earlier results or
reuse an existing case database. Exact commands/environment overrides and
before/after hashes are in each `result.json`. The common invocation shape was:

```sh
macparakeet-cli-runtime transcribe <public-fleurs-file> \
  --engine cohere --language <ja|ko|zh> --mode raw --speaker-detection off \
  --no-history --database <owned-case>/history.sqlite --format json
```

Observed stderr intervals from encoder-load start to decoder-load start were
35.330 seconds for Japanese, 0.151 seconds for Korean and 0.144 seconds for
Mandarin. This is consistent with a warmer later load path, but cache/host state
was not controlled or reset. The earlier bounded attempts used another build
binary identity, and executable-specific CoreML caches may differ. Neither the
wall times nor these log intervals are a controlled latency A/B or a performance
promise.

All successful follow-ups finished below both the new and old time limits.
They show the samples can complete; they do not prove the original attempts
would have completed merely by waiting longer, nor resolve the variability of
cold encoder loading. Preserve the older failures as harness-limit observations
instead of relabeling them as language-specific inference failures.

## Durable evidence

The following reviewed copies contain public transcripts, case metadata and
complete short runtime logs. Absolute QA/fixture roots were replaced with
`<QA_ROOT>` / `<PUBLIC_FLEURS>`; no transcript or progress content was removed.
The [manifest](evidence/cohere-extended/manifest.json) records both original
local-file SHA-256 and sanitized-copy SHA-256. Output hashes inside result JSON
refer to original raw files; use the manifest to verify these curated files.
No SQLite database, model cache, audio or private environment values were copied.

- [Combined validation](evidence/cohere-extended/summary.json)
- Japanese: [result](evidence/cohere-extended/ja-result.json), [stdout](evidence/cohere-extended/ja-stdout.json), [stderr](evidence/cohere-extended/ja-stderr.log)
- Korean: [result](evidence/cohere-extended/ko-result.json), [stdout](evidence/cohere-extended/ko-stdout.json), [stderr](evidence/cohere-extended/ko-stderr.log)
- Mandarin: [result](evidence/cohere-extended/zh-result.json), [stdout](evidence/cohere-extended/zh-stdout.json), [stderr](evidence/cohere-extended/zh-stderr.log)

Original local working directory: `<QA_ROOT>/cohere-extended`.
Its `run.py` and `run_followups.py`, raw output files, owned databases and
conversion files remain available locally. The [earlier sample matrix](audio-runtime.md)
retains the original timeout history. Curation did not rerun inference or modify
product code.
