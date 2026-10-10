# Jev request-shape evaluation, 2026-10-09

What was measured against live Jev (`jev-1.13.0`, the only model; `jev-latest`
and `jev-preview` both point at it), how, and what shipped because of it.

## Method

- **Corpus.** 48 labeled cases over 7 saved observations from real apps on this
  Mac (Finder, Gmail and Google in Chrome, Notes, YouTube, GitHub), taken from
  `~/Library/Application Support/MacParakeet-Dev/logs/voice-control/sessions/`.
  Goals are paraphrases, so the local router falls through to Jev: 34
  single-action presses or fills, 1 already-finished view, 3 requests nothing on
  screen can do, and 10 multi-step goals (labeled `scope: multi`), 48 in all. The
  first runs used 40 of them: every case except the 8 multi-step goals added
  later; two of those 40 (the search goals) were relabeled multi-step when
  scope was measured. Labels are
  acceptable target ids. The corpus holds personal interface text and stays out
  of git; only these aggregates are recorded.
- **Harness.** `scripts/dev/voice_control_jev_eval.py`. The router decides first
  through `macparakeet-cli voice-control replay --json` (no Jev call), which also
  reports the exact offered option ids. The harness then rebuilds the open-ended
  request from the saved observation in each variant and sends it.
- **Scoring.** *Right act*: passes the gate and is correct. *Wrong act*: passes
  the gate and is wrong (the number that matters for safety). *Clarify*: below
  the gate. Repeats measure order sensitivity (production variant) or service
  noise (fixed variants).
- Cost of everything below: well under $1 of Jev usage.

Runs predate the text-twin filter moving into the CLI's offered set; the
`_dedup` variants were measured against the pre-filter option list.

## Finding 1: option order was random per launch

Swift `Dictionary` iteration and `JSONEncoder` key order are seeded per process
(confirmed with a standalone probe; a custom keyed container does not help).
`jev-1.13` leans toward the first-listed Choice option (TypeSafe jaggedness page,
reviewed 2026-10-02).

Same saved Finder observation and goal, six separate CLI processes:

| Order | `kind` confidence across runs | Outcome |
|---|---|---|
| Random (production before this change) | 0.34 to 0.95 | 5 press, 1 clarify |
| Fixed (`SWIFT_DETERMINISTIC_HASHING=1`) | 0.86 to 0.89 | 4 press |

The spread is the wire format, not Jev; fixed-order service noise is about ±0.03.
Across the corpus, three random shuffles changed the outcome in 3 of 40 cases.

## Finding 2: describing each control once is as accurate and 4x cheaper

40 cases (first run) and 40 cases × 3 repeats (second run):

| Variant | Right | Wrong | Clarify | p50 ms | Input tokens |
|---|---|---|---|---|---|
| Production (random order, target lines repeated as criteria) | 91% | 2% | 8% | 254 | 15,380 |
| Fixed traversal order | 91% | 1% | 8% | 257 | 15,380 |
| Fixed order, text twins removed | 90% | 1% | 9% | 243 | 12,408 |
| Targets once in state, `null` criteria | 91% | 2% | 7% | 186 | 4,320 |
| Same, text twins removed (shipped) | 92% | 2% | 6% | 182 | 3,625 |
| Averaging forward and reversed option order | 85% | 2% | 12% | 268 | 18,814 |

Averaging two orderings did not help and cost tokens; one ecosystem project
reported it can make a wrong answer actionable. Not shipped.

Through the shipped Swift client the same Finder request went from 27,299 to
10,468 bytes and from about 270–360 ms to 160–210 ms per decision, and is now
byte-identical across launches.

## Finding 3: a scope head is safe to act on

A `scope` Choice (`multi` / `single`) asked in the same request:

| Order | All | Single | Multi | Multi read as confident single |
|---|---|---|---|---|
| `multi` first (shipped) | 79% | 58/76 | 16/18 | **0** |
| `single` first | 79% | 58/76 | 16/18 | 0 |

Most "misses" were labeling choices that the model got arguably right (`write a
new email` is multi-step; impossible requests read as multi). What matters is the
dangerous direction: no multi-step goal was ever confidently single, so ending a
task after a confident single action never stops a search or a form early. Policy
shipped: finish only on `single` with confidence ≥ 0.5, on the first decision of
an unamended goal.

## Finding 4: `finished` needs its own bar

The remaining wrong acts were false completions: a Finder Recents window read
as "my downloads" (`finished` at 0.52 to 0.68). A same-request "goal visible"
Noul, the most common pattern in new repos, scored that case 0.59 to 0.64 and did
not separate it; not shipped. A literal criterion ("the requested folder, page,
item or setting is open or set; a similar view does not count") lowered the false
`finished` to about 0.53 with no loss of right acts (91%). True completions scored
about 0.87. Shipped: the literal criterion plus a 0.6 gate for `finished`.

Gate sweep on the shipped shape (right / wrong): 0.5: 91% / 4%, 0.6: 84% / 0%,
0.7: 79% / 0%. The target gate stays 0.5; split targets now become numbered
picks instead of clarifications.

## Finding 5: value-span order is fine as designed

16 fill goals, value head alone:

| Span order | Correct | Wrong acts |
|---|---|---|
| Cue tails first (designed, now actually on the wire) | 16/16 | 0 |
| Shortest first | 15/16 | 0 |
| Reversed | 16/16 | 0 |
| Shuffled | 15/16 | 0 |

## Live error shapes

Probed directly: state over the token limit returns
`400 {"detail":{"error_type":"max_tokens_exceeded"}}`; a bad key `401
authentication_error`; more than 255 options `400 Too many choices`. The client
now maps these to "too large", "key rejected" and "unavailable".

## Live app observations (dry runs, 2026-10-09)

- Observation plus decision took about 150–260 ms end to end on Finder and cmux
  windows (walks of 49–126 nodes in 22–92 ms).
- With the wrong app frontmost, Jev answered `none` at 0.98 instead of guessing.
- Finder, `sort these by size`: would press Size. Correct.
- Activating Finder by script can leave the desktop as Finder's focused window;
  Voice Control then observes the desktop. In real use the window the person
  clicked is focused.
- Finder sidebar items are not exposed as pressable Accessibility controls with
  screen text off; Jev reaches for the Go menu instead. Screen text, or a Finder
  sidebar adapter, is the fix.
- A dry run that ended in a question left the panel awaiting an answer and
  blocked later dry runs. Fixed.

## Not measured

Microphone-to-effect latency, wrong-target rate on live presses, and the
overlay on a live desktop: the machine was in active use, and a live press would
have landed in the window being typed in. Rendered offscreen instead.
