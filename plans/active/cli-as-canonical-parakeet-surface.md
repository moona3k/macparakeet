# Plan: MacParakeet CLI as the canonical Parakeet-on-Apple-Silicon surface

> Status: **ACTIVE** — strategic plan, post-PR-#138, pre-v0.6.0
> Author: agent (Claude) + Daniel
> Date: 2026-04-25
> Related: PR #138 (CLI prompts + JSON sweep, merged), PR #141 (gitignore journal/, merged), PR #144 (CLI 1.0 + AGENTS.md + integrations/, merged), PR #145 (rollout artifacts + registry drafts)
>
> **Post-launch correction (2026-04-25):** This plan repeatedly refers
> to OpenClaw skills as `SOUL.md` files. That was wrong. ClawHub
> (the OpenClaw skill registry) publishes skills as **`SKILL.md`** with
> frontmatter; `SOUL.md` is the format used by a different agent
> registry, onlycrabs.ai. The integrations/ directory has been
> corrected (`integrations/openclaw/SOUL.md` was renamed to
> `integrations/openclaw/README.md`). Inline `SOUL.md` references in
> the body below are preserved as the original strategic snapshot but
> should be read as `SKILL.md` for any OpenClaw/ClawHub action. See
> PR #145's `plans/active/registry-submissions/clawhub.md` for the
> verified submission flow.

---

## TL;DR

**The reframe:** MacParakeet is the canonical Swift-native CLI for Parakeet TDT on Apple Silicon, with a beautiful Mac GUI on top. The CLI is the foundation; the GUI is one (excellent) consumer of it. Apple Silicon AI-agent operators are a real, growing audience that needs exactly this.

**Why now:** OpenClaw (acquired by OpenAI Feb 2026, 350K GitHub stars, 500K running instances) and Hermes Agent (Nous Research, 95K stars in 7 weeks) are exploding. Both deploy as daemons on user-controlled compute (Mac mini, VPS). Both shell out to local CLIs via `AGENTS.md`/`SOUL.md` skill specs. **Voice/STT is the documented gap** in their stacks today — Whisper.cpp is too slow without ANE; OpenAI Whisper API breaks privacy + costs money.

**The slot is open and winnable.** Nobody is currently sitting in the chair labeled *"canonical Swift-native Parakeet CLI for Apple Silicon, batteries included."* parakeet-mlx (Python) is closest in spirit but structurally weaker (Python deps, no SQLite memory layer, no prompts/diarization). MacParakeet — after the PR #138 CLI work — is structurally there. The remaining gap is **claiming the position deliberately.**

---

## Market context (as of April 2026)

### OpenClaw

- **350K+ GitHub stars · 70K forks · 1.6K contributors** (from 245K in early March → +100K in ~5 weeks)
- **38M monthly visitors · 3.2M active users · 500K running instances**
- **44,000+ ClawHub skills** in the registry
- **180 startups** building on top, generating $320K+/month
- **Acquired by OpenAI in February 2026**
- **NVIDIA built an enterprise stack on it**
- Gartner: OpenClaw will be the default OSS choice for the 40% of enterprises deploying autonomous agents by EOY 2026

### Hermes Agent (Nous Research)

- Released **Feb 25, 2026** — **95,600 stars in 7 weeks**
- "Matched the combined historical growth curves of LangChain and AutoGen"
- v0.10.0 (Apr 16): 118 skills, three-layer memory, 6 messaging platforms (Telegram/Discord/Slack/WhatsApp/Signal/Email)
- v0.8.0 (Apr 8): React/Ink CLI rewrite, pluggable transport, AWS Bedrock support
- macOS install: literal one-liner. Hermes-on-Mac-mini is a documented happy path.
- Uses **`AGENTS.md` convention** at repo root — becoming the de facto cross-agent integration spec
- `awesome-hermes-agent` registry exists

### Why Apple Silicon specifically

- M4 Pro Mac mini at $1,399, unified memory, idles at ~8W, silent. The de facto "always-on personal AI compute box."
- ANE (Apple Neural Engine) gives Parakeet TDT 155× realtime + 2.5% WER + ~66 MB working memory
- VPS deployments of Hermes/OpenClaw can't access ANE → that's our defensible niche
- The audience is "Apple Silicon agent operators" (Mac mini dominant, MacBook Pro + Mac Studio also valid)

---

## Architecture (after this reframe)

```
NVIDIA Parakeet TDT 0.6B v3 (public weights, NeMo)
                │
                ▼
FluidAudio (CoreML/ANE Swift wrapper, public)
                │
                ▼
   ┌────────────────────────────────────┐
   │   MacParakeetCore (Swift library)  │
   │   STT + DB + Prompts + LLM         │
   └─────────────┬──────────────────────┘
                 │
        ┌────────┴────────┐
        ▼                 ▼
  macparakeet-cli    MacParakeet.app
  (foundation)       (GUI consumer)
        │
        ├──► AGENTS.md (Hermes / Codex CLI / generic)
        ├──► SOUL.md (OpenClaw)
        ├──► brew install (headless install)
        └──► [future] MCP server, more clients
```

The CLI is the load-bearing surface. The GUI is one well-crafted client of it. Agents are other clients. MCP, when/if shipped, is a future protocol-layer client. All read from the same SQLite + STT pipeline.

---

## Competitive positioning

| Tool | Stack | Strengths | Gaps for agent use |
|---|---|---|---|
| **parakeet-mlx** (Python) | Python + MLX | Works, simple syntax, growing | Python deps, no memory layer, no prompts/history, no built-in diarization, not Swift-native |
| **whisper.cpp** | C++ | Mature, ubiquitous | Different (worse) model, no ANE, slower, no diarization |
| **FluidAudio CLI demos** | Swift | Same backend we use | Not productized — toys |
| **VoiceInk** | Swift, GPL, FluidAudio | GUI app | No CLI focus |
| **MacWhisper / Superwhisper / WisprFlow** | Various | Polished GUI consumer apps | Closed-source, no CLI |
| **MacParakeet (post-#138)** | Swift native, FluidAudio, SQLite | **Best model + best runtime + memory layer + JSON CLI + GPL** | **Currently lacks the *positioning* + *distribution* to be discovered as canonical** |

---

## Action plan (six items, ordered by leverage)

### 1. Promote `macparakeet-cli` to a versioned public surface

**Why:** The CLI was previously framed as `"MacParakeet developer CLI (internal; used for AI-assisted development and testing)"` in its own `--help` abstract. Once OpenClaw/Hermes users build skills against `macparakeet-cli flow words add`, that's a public contract. Breaking changes need migration paths.

**What:**
- Adopt **semver** for the CLI surface. Stamp `1.0.0` on it (it's mature enough — the PR #138 work landed CRUD, JSON, validation, tests).
- Create `CHANGELOG.md` scoped to CLI changes. Existing app changelog is for the app; the CLI deserves its own.
- Add a **deprecation policy** doc: "CLI surface is semver. Breaking changes require N versions of `--legacy-X` shim and a release-note callout."
- Bump `macparakeet-cli --version` from `0.1.0` to `1.0.0` in `Sources/CLI/MacParakeetCLI.swift`.

**Effort:** 0.5 day.

### 2. Ship `brew install moona3k/tap/macparakeet-cli`

**Why:** Apple Silicon agent operators want CLI without dragging a `.app` into `/Applications`. Headless installs (Mac mini via SSH, launchd contexts) need a clean `brew install`.

**What:**
- Create a Homebrew tap repo: `moona3k/homebrew-tap`
- Formula `macparakeet-cli.rb` that:
  - Downloads the standalone CLI binary (or builds from source)
  - Installs bundled FFmpeg + yt-dlp dependencies
  - Sets up `~/Library/Application Support/MacParakeet/` paths
  - Pins to a tagged release matching the CLI semver
- Document install path in README + `/agents` website page
- Optional: `curl -sSL macparakeet.com/install-cli.sh | bash` as an alternative one-liner

**Effort:** 1 day.

**Dependency:** Need a way to ship the CLI binary standalone (not bundled in `.app`). Options:
- Build from source via `swift build --product macparakeet-cli` in the formula (slow but simple)
- Pre-built signed binary attached to GitHub releases (faster install, more release work)

Recommend pre-built binary path for distribution speed.

### 3. Write `AGENTS.md` at repo root

**Why:** `AGENTS.md` is becoming the cross-agent convention (Hermes uses it, Codex CLI reads it, Claude Code respects it). Single canonical spec serves all agent integrations.

**What:**
- File at `/AGENTS.md` (repo root)
- Documents:
  - When an agent should use MacParakeet (transcription, prompt-running, history search, vocab management)
  - Every CLI command with example inputs + expected JSON output shape
  - Privacy notes (all local, no network unless YouTube/LLM)
  - Error-handling conventions (exit codes, stderr vs stdout)
- Per-agent thin wrappers in `integrations/`:
  - `integrations/openclaw/SOUL.md` — points to root AGENTS.md, adds OpenClaw-specific install
  - `integrations/hermes/README.md` — Hermes skill registration
  - `integrations/README.md` — landing page for the integration story

**Effort:** 1 day.

### 4. `/agents` page on macparakeet.com

**Why:** Position page targeting the "Apple Silicon agent operator" persona explicitly. Acquisition surface for the agent audience.

**What:**
- New page on the marketing site: `macparakeet.com/agents`
- Headline: *"The local STT layer for your Apple Silicon AI agent."*
- Sections:
  - Why MacParakeet for agents (ANE-accelerated, GPL, JSON CLI, no cloud)
  - Quickstart: brew install + Hermes/OpenClaw skill registration
  - Example: "Hey OpenClaw, what was my last meeting?" → real CLI output
  - Privacy stance (everything local except optional YouTube/LLM provider)
  - Link to AGENTS.md + integrations/
- Mention in main homepage: small "For AI agents →" link in nav or footer

**Effort:** 0.5 day.

### 5. Submit to ClawHub + awesome-hermes-agent

**Why:** Distribution. The skill registries are how agent users discover integrations.

**What:**
- PR to `awesome-openclaw-skills` registry — submission with link back to canonical SOUL.md / AGENTS.md
- PR to `awesome-hermes-agent` registry — same
- Cross-post to:
  - r/LocalLLaMA: "Local Whisper alternative for Mac mini AI agents"
  - Hacker News: "MacParakeet — canonical Parakeet CLI for Apple Silicon agent operators"
  - Nous Research Discord
  - OpenClaw Discord
- Time these to land alongside v0.6.0 release for compounding momentum

**Effort:** 0.5 day for the PRs + community posts (excluding response/moderation time)

### 6. Blog post pinned to v0.6.0

**Why:** Headline narrative for the reframe. Makes the strategic positioning shippable as content.

**What:**
- Title: *"MacParakeet, reframed: the canonical Parakeet CLI for Apple Silicon"* (or similar)
- Story arc:
  - The agent moment is here (OpenClaw + Hermes data)
  - Voice/STT is the gap in the local agent stack
  - MacParakeet was built for individual macOS users — but the architecture happens to be exactly what agents need
  - Today: macparakeet-cli 1.0, AGENTS.md, brew install path, registry submissions
  - Future: same direction, more depth (MCP later, more agent integrations as ecosystem matures)
- Link to: AGENTS.md, integrations folder, `/agents` page, Hermes/OpenClaw quickstarts
- Submit to HN, post to relevant communities

**Effort:** 0.5 day.

---

## Total estimated effort: ~3-4 focused days

Items 1-3 are deep work. Items 4-6 are mostly content + light coding. All can be done in parallel with v0.6.0 release prep.

---

## What's explicitly out of scope (for now)

- **MCP server.** Different niche (Claude Desktop / Cursor users), more effort, no validated demand. Defer until OpenClaw/Hermes integration shows real adoption signal.
- **Bundle agent integration into v0.6.0 release notes.** v0.6.0 should headline meeting-notepad for current users. Agent integration is a parallel narrative.
- **Pivot away from GUI users.** They remain the largest and most loved audience. The reframe is *additive*, not subtractive.
- **Renaming.** "MacParakeet" stays. CLI stays as `macparakeet-cli`. Brand is good.
- **Whisper.cpp integration.** Stick with FluidAudio + Parakeet TDT. That's the moat.
- **Cross-platform CLI (Linux/Windows).** Apple Silicon is the entire premise; non-Apple-Silicon defeats the ANE advantage.

---

## Risks / things to watch

1. **Audience size unknown.** OpenClaw/Hermes star counts are aspirational signals, not paying users. Apple-Silicon-agent-operator subset is even smaller. Mitigation: cheap experiment, observe traction.
2. **Skill registry formats may shift** post-OpenAI's OpenClaw acquisition. Keep specs lightweight and centralized so re-emitting in a new format is mechanical.
3. **Maintenance burden of versioned CLI surface.** Once committed to semver, breaking changes have a cost. Already low-risk because the CLI is small + well-shaped.
4. **Positioning confusion** between individual-user audience and agent-operator audience. Mitigation: separate pages on the website, single brand, both legitimate.
5. **Competitor catches up.** parakeet-mlx could grow a memory layer + diarization. First-mover positioning wins by being there first AND having a structurally better (Swift native, better packaging) base.
6. **OpenAI may push proprietary alternatives** post-OpenClaw acquisition. Risk if they ship a first-party Whisper-on-Apple-Silicon solution as part of OpenClaw. Mitigation: GPL + local + Parakeet (not Whisper) gives differentiation regardless.

---

## Sequencing relative to v0.6.0

| Phase | When | What |
|---|---|---|
| v0.6.0 prep + release | Imminent (separate track) | Meeting-notepad headliner; cut release with usual flow |
| Item 1 (semver + CHANGELOG) | Can ship before or with v0.6.0 | Doesn't touch app code |
| Item 2 (brew tap) | Can ship before or with v0.6.0 | Separate repo |
| Item 3 (AGENTS.md + integrations/) | Can ship before or with v0.6.0 | Pure docs |
| Item 4 (/agents page) | Pair with v0.6.0 marketing | Website work |
| Item 5 (registry submissions) | Land alongside v0.6.0 release | Maximize momentum |
| Item 6 (blog post) | Day-of v0.6.0 release | Single headline narrative |

**The agent integration work is decoupled from v0.6.0 code-wise but coupled in marketing timing.** Done right, both ship the same week with reinforcing narratives.

---

## Open decisions

1. **Bump CLI version to `1.0.0` or `0.6.0`?** Semver suggests 1.0 (it's mature, public). Coupling to app version suggests 0.6.0. **Recommend 1.0.0** — the CLI is its own contract.
2. **Brew tap repo name?** `moona3k/homebrew-tap` (general) or `moona3k/homebrew-macparakeet` (specific)? **Recommend general tap** so future tools can live alongside.
3. **`/agents` page or `/cli` page?** Audience-framed (`/agents`) vs surface-framed (`/cli`). **Recommend `/agents`** — leads with persona.
4. **Standalone binary distribution path?** Build-from-source in formula (simple, slow) vs pre-built signed binary (fast, more release work). **Recommend pre-built** for installation UX.
5. **Update `CLAUDE.md`** to reflect the reframe (CLI as canonical surface, agent operators as second audience)? **Recommend yes** — keep the codebase context current.

---

## Success signals to watch (4-8 weeks post-launch)

- ClawHub and awesome-hermes-agent listings get accepted + PRs merged
- GitHub stars trajectory on macparakeet repo
- Brew tap install count (if telemetry exists, or via Homebrew analytics)
- `/agents` page traffic
- Mentions in OpenClaw/Hermes Discord / r/LocalLLaMA
- New GitHub issues from agent operators (different shape than current GUI-user issues)
- Pull requests from non-MacParakeet users adding integration improvements

If any of these light up meaningfully → double down (MCP server, more agent integrations, deeper docs).
If all stay flat → the thesis didn't validate; cost was small (3-4 days), no regret, GUI work continues unaffected.

---

## References

- PR #138: CLI prompts subcommand + structured JSON output (merged 2026-04-25)
- PR #140: Retire legacy `Transcription.summary` mirror (merged 2026-04-25)
- PR #141: Gitignore `journal/` directory (merged 2026-04-25)
- `plans/active/cli-prompts-and-json-output.md` — the immediate predecessor plan
- ADR-013: Prompt Library + Multi-Summary Architecture
