# Brief 06 — GUI lagging the CLI (reverse parity)

One concern: identify GUI product gaps where the CLI already has a better automation/library capability, and judge whether a *small* GUI follow-through is warranted.

## Settled

- CLI has ranked segment FTS (`search`), bounded `transcript` context, and `cards`. Research notes have claimed GUI library search is still substring. Verify against current `TranscriptionLibraryViewModel` / search UI — old research may be stale.
- Do not propose building a second knowledge engine. If GUI should catch up, it must reuse Core search/cards APIs.
- Large UX redesigns are out of scope for this pass unless a tiny wiring gap exists.

## Investigate

- Library search implementation vs CLI `search`
- Cards visibility in GUI
- Meeting artifact folder / markdown in GUI vs `meetings artifact`
- Retranscribe in GUI vs CLI
- Meeting import/split GUI vs CLI (plans claimed GUI missing at some point)
- Export DAPT in GUI

## Fences

- Read-only. Write only: `docs/research/2026-09-17-cli-gui-parity/06-gui-lag.md`
- Recommend skip unless the GUI gap is a small reuse of existing Core.

## Done

Verified reverse gaps with evidence; ship/skip recommendation for this PR wave.
