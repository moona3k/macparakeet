# Apple Intelligence quality / latency A/B (#1062)

> Status: live product-task bake-off on one Tahoe host, not a Phase 0 gold-set
> Date: 2026-09-16 (ran 2026-09-17 UTC)
> PR: [#1077](https://github.com/moona3k/macparakeet/pull/1077)
> Issue: [#1062](https://github.com/moona3k/macparakeet/issues/1062)

## What this is (and is not)

The earlier PR table that all three Foundation Models paths returned `PING` is a
**path-correctness smoke test**. It is not an accuracy A/B.

This note is the quality / latency bake-off on MacParakeet's actual LLM
surfaces: dictation cleanup (`llm transform`), meeting summary (`llm
summarize`), and grounded Ask (`llm chat`).

**WER does not apply.** Apple Intelligence here is `SystemLanguageModel`, a
chat LLM, not an ASR engine. Speech WER belongs to Parakeet / WhisperKit /
SpeechTranscriber, not this provider.

This is **not** the local-LLM Phase 0 eval
([`plans/active/2026-06-27-on-device-local-llm-phase0-eval.md`](../../plans/active/2026-06-27-on-device-local-llm-phase0-eval.md)):
no SARI, no AlignScore, no cloud LLM-judge, n=1 English synthetic slice. Do not
treat the scores as a public "recommend Apple Intelligence over cloud" gate.

## Host

| Field | Value |
|---|---|
| Mac | Apple M4 Pro, 48 GB |
| OS | macOS 26.6.2 (25G83) |
| Apple Intelligence | `.available` after enable + model download |
| Product path | `macparakeet-cli llm … --json` from `feat/issue-1062-apple-intelligence` |
| Cloud arm | skipped — stored `OPENAI_API_KEY` rejected as invalid |

## Arms

| Arm | Why |
|---|---|
| Apple Intelligence (`--provider appleIntelligence`) | The new on-device provider |
| Ollama `qwen3.5:4b` | MacParakeet's default local Ollama model (~3.4 GB) |
| Ollama `llama3.2:3b` | Size-matched ~3B local peer (~2.0 GB) |

Ollama was started for this run (`ollama serve`). First call per model includes
weight load. Apple Intelligence was already warm from the earlier PING smoke.

## Frozen fixtures

Synthetic English text only. No user meetings.

**Dictation (cleanup).** Filler-heavy, with entities that must survive:

```
um so yeah uh this is for the Q3 pipeline review with Sarah Chen from Acme.
we closed 1.4 million last Tuesday, that's 2026-09-15, and she wants the demo
by Friday at 3pm. don't forget the Zoom link is https://zoom.us/j/5551234567.
oh and the invoice number is INV-8842. like you know we should also ping
Marcus about the 16 gig RAM Mac minis.
```

Cleanup instruction: remove `um` / `uh` / `like` / `you know` / `so yeah` and
false starts; keep every name, number, date, URL, and identifier exactly; add
no facts.

**Meeting (summary + Ask).** Two speakers, one named Priya; facts: 14 open
issues, $12,500 budget, ship v0.8.0 on 2026-09-22, Jordan cuts the tag, Priya
owns release notes by Thursday, Apple Intelligence inclusion is an open
question.

Ask questions:

1. When is v0.8.0 supposed to ship? Answer with the date only.
2. Who owns the release notes?
3. What is the budget number?
4. How many open issues are there?
5. Trap: What did Alex decide about the London office? (neither is in the source)

## Metrics

| Metric | How |
|---|---|
| Latency | CLI `latencyMs` (end-to-end, not TTFT) |
| Cleanup fidelity | 10/10 entity+identifier hits; filler regex `\b(um\|uh\|you know\|so yeah)\b` |
| Summary fidelity | 7/7 fact hits, date paraphrases allowed (`September 22, 2026` = `2026-09-22`) |
| Grounded Ask | 4/4 fact hits |
| Hallucination trap | PASS if the model refuses and does not invent a decision |

## Results

### Quality

All three arms tied on this slice.

| Task | Apple Intelligence | Ollama qwen3.5:4b | Ollama llama3.2:3b |
|---|---|---|---|
| Cleanup entities | **10/10**, fillers gone | **10/10**, fillers gone | **10/10**, fillers gone |
| Summary facts | **7/7** | **7/7** | **7/7** |
| Grounded Ask | **4/4** | **4/4** | **4/4** |
| Trap (Alex / London) | **PASS** — "did not make any decisions" | **PASS** — "no mention" | **PASS** — "no mention of Alex" |

Apple's cleanup kept every identifier and dropped the fillers. Qwen's summary
was longer and more "meeting-notes-shaped"; Apple and Llama stayed shorter.
None of the three invented a London-office decision.

### Latency (`latencyMs`)

| Task | Apple Intelligence | qwen3.5:4b | llama3.2:3b |
|---|---:|---:|---:|
| Cleanup | 2,440 | 7,856 | 24,293 (cold load) |
| Summary | 3,604 | 15,526 | 3,935 |
| Ask: ship date | 460 | 1,150 | 406 |
| Ask: owner | 542 | 3,417 | 323 |
| Ask: budget | 471 | 1,272 | 229 |
| Ask: issue count | 450 | 1,016 | 214 |
| Ask: trap | 562 | 2,094 | 358 |

Warm short Ask (after each model had already run): Apple ~450–560 ms, Llama
~210–410 ms, Qwen ~1–3.4 s. Llama's 24 s cleanup is first-load, not generation.
Apple was warm. Do not quote the cold Llama number as steady-state.

End-to-end `latencyMs` is not time-to-first-token. Streaming TTFT was not
measured on this pass.

## Read

On short English cleanup / summary / Ask, Apple Intelligence matched the local
3B/4B Ollama arms on this frozen slice and was faster than Qwen 4B once warm.
That supports offering it as an **opt-in on-device path** for Transforms,
dictation cleanup, and short Ask. It does **not** support making it the
default, claiming cloud parity, or sending long meetings into the 4096-token
window.

## Reproduce

From a Tahoe Mac with Apple Intelligence available and Ollama serving
`qwen3.5:4b` / `llama3.2:3b`:

```bash
macparakeet-cli llm transform --provider appleIntelligence dictation.txt \
  --prompt 'Clean this dictation. Remove filler… Keep every name, number, date, URL, and identifier exactly.' \
  --json
macparakeet-cli llm summarize --provider appleIntelligence meeting.txt --json
macparakeet-cli llm chat --provider appleIntelligence meeting.txt \
  --question 'When is v0.8.0 supposed to ship? Answer with the date only.' --json
```

Swap `--provider ollama --model qwen3.5:4b` (or `llama3.2:3b`) for the local
arms.
