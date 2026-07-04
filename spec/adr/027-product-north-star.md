# ADR-027: Product North Star — Private Speech Memory

> Status: ACCEPTED (direction; individual capabilities land through their own
> plans/ADRs)
> Date: 2026-07-03
> Related: ADR-002 (local-only), ADR-026 (ASR engine strategy, PR #677),
> ADR-014 (meeting recording), spec/00-vision.md (product vision, updated in
> the same PR)

## Context

MacParakeet ships three capture modes — system-wide dictation, file/media
transcription, and meeting recording — plus Transforms. Each mode is a solid
standalone tool, and to date the product identity has been "the fastest, most
private voice app for Mac." Three forces make it worth stating where those
modes converge:

1. **Raw ASR is commoditizing.** Apple now ships a zero-download engine in
   the OS; open local models keep improving (ADR-026). "We transcribe
   accurately and fast" erodes as a durable identity, even though it remains
   table stakes.
2. **Value migrates up-stack.** Once capture is reliable, the valuable thing
   is the *accumulated* text: searching it, asking questions of it, and
   building on it. The local-LLM plan
   (`plans/active/2026-06-27-on-device-local-llm.md`) makes that layer
   private too.
3. **The local-first posture is a structural prerequisite no cloud product
   can copy.** A corpus of everything a user has said and heard is a
   liability in the cloud and an asset on-device. MacParakeet's architecture
   is the only place such a corpus can credibly live.

Separately, agents running on the user's machine are becoming a second
consumer of local context. `macparakeet-cli` is already a versioned public
contract, and third parties have built on it (community Obsidian plugin).

## Decision

### 1. The north star

**Every word you speak or hear on your Mac becomes private, permanent, and
useful — on your machine, owned by you, readable by you and your agents.**

Short form: **MacParakeet is the private speech memory of your Mac.**

The three capture modes are intake valves for one compounding local corpus:
dictation captures what you say, meetings capture what you discuss,
file/media capture what you consume. The existing product promise (fastest,
most private, simplest) is unchanged as the day-one experience; this ADR
states the destination those modes converge toward.

### 2. The Library becomes the center of gravity

The one genuinely new investment this direction demands: the Library evolves
from a list of past sessions into the product's core surface — unified
search across all three modes, question-answering over the corpus, and
export. Scope guard: **search + QA + export, not a PKM.** MacParakeet does
not become a note-taking app, a knowledge graph, or an editor.

### 3. Agent access is a first-class product surface

Anything the user can do with their corpus, their local agents should be
able to do through a stable contract. Near-term shape: read access to the
corpus via `macparakeet-cli` (search/ask surfaces), governed by the existing
CLI contract discipline (`spec/contracts/`, CLI CHANGELOG). MCP or deeper
integrations remain demand-driven, not speculative.

### 4. Ambient capture is parked, not rejected

Unlike cloud ASR — which ADR-002/ADR-026 rule out permanently — always-on or
ambient capture (session-less listening, screen context) is a deliberate
*someday, maybe*. The product stays session-based: every capture is
explicitly started by the user. Revisiting ambient capture requires its own
ADR with a privacy design, not incremental drift.

### 5. The decision filter

Every proposed feature must do at least one of:

- **capture speech better** (reliability, accuracy, coverage),
- **make the corpus more useful** (search, QA, summaries, export), or
- **hand it safely to the user and their agents** (contracts, integrations).

Otherwise it does not ship. This restates the existing simplicity rule in
terms of the north star.

## Consequences

- Near-term roadmap is already aligned: capture reliability (ADR-025 /
  meeting AEC), accuracy and language coverage (ADR-026 plans), and the
  on-device LLM plan are the first three stairs. The Library/search/QA
  investment is the new fourth stair and should be planned as such.
- Persistence and durability of transcripts get north-star weight: the
  corpus is the product's long-term asset, so artifact durability, recovery,
  and export remain non-negotiable (existing product rule, reinforced).
- "Use and forget" framing in older docs is superseded: the product is
  intended to compound in value with use.

## Open question

The boundary with Oatmeal (the separate "meeting memory" product concept in
spec/00-vision.md) narrows under this north star: cross-mode search and
corpus QA land in MacParakeet. Deeper intelligence (entity extraction,
knowledge graphs, team features) remains out of MacParakeet's scope. Whether
Oatmeal continues as a distinct product is deliberately left open here.
