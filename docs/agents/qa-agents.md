# QA Agents — Landscape & Plays

> Status: **DATED RESEARCH SNAPSHOT** — last updated 2026-05-03. Reverify tool
> availability, maturity, platform support, and pricing before adoption.

## Why this doc

Every quarter someone pitches an "AI does QA" tool. Most are web-first or
mobile-first. MacParakeet is a menu-bar macOS app with a non-activating
`KeylessPanel` overlay, global dictation hotkeys, and TCC-gated
microphone/screen-recording flows. The general AI-QA frontier doesn't speak
our shape yet. This doc tracks who's close, where the real gaps are, and the
hybrid 2026 play that actually works for us today.

## Landscape at a glance

### Web / browser

| Tool | OSS? | Why it matters |
|---|---|---|
| **Playwright Test Agents** (Microsoft, MIT) | Yes | The architectural blueprint of 2026: `planner / generator / healer` decomposition + a11y-tree-first execution + ~75% self-heal on broken selectors. Even though we're not a web app, **steal the shape**. |
| **Playwright MCP** | Yes (MIT) | Reference impl that bridges LLMs ↔ live browser via MCP. Maps cleanly onto how an MCP server for native Mac would be designed. |
| **Stagehand** (Browserbase) | Apache-2.0 | `act/extract/observe` AI primitives layered on top of *deterministic* Playwright. Caches replay so repeats skip the LLM — pattern worth copying for any AI-driven test runner. |
| Browser-Use, Skyvern, Mabl, Testim, Functionize | Mixed | Strong on web; out of scope for MP unless [macparakeet.com](https://macparakeet.com) regression ever lands in scope. |
| **Anthropic Computer Use** + **OpenAI Operator** | Closed | Vision-driven, can drive native Mac apps. Useful for exploratory dogfooding. Too slow + non-deterministic for regression. |

### Backend / contract

Mostly N/A for MacParakeet — we're not a REST product. Two slivers worth a
beat:

- **Schemathesis** (Apache-2.0, property-based fuzzing from OpenAPI) on the
  Cloudflare Worker telemetry endpoint and feedback Pages Function would
  catch the kind of allowlist drift that hit us per the
  `feedback_telemetry_allowlist.md` memory.
- **Prism** mocks of the LLM-provider HTTP shapes (OpenAI-compatible /
  Anthropic / LM Studio / Ollama) would pin contracts MP consumes from
  `OpenAICompatibleProvider`. Useful but not urgent.

### Native macOS app QA — the gap frontier

| Tool | Maturity | What it gives us | Where it breaks |
|---|---|---|---|
| **XCUITest** (Apple) | Mature; Xcode 26 added record/replay + parallel suites + video logs | Standard XCTest UI driver | Won't drive `NSStatusItem` reliably; fights `KeylessPanel`; no global-hotkey simulation; needs `accessibilityIdentifier` everywhere |
| **swift-snapshot-testing** (PointFree) | Mature, ~7k stars | Deterministic SwiftUI/AppKit snapshots | ~95% pixel-match floor across local Mac vs CI; needs a pinned CI runner |
| **Appium + appium-mac2-driver** | Mature for std macOS, rough at edges | WebDriver against `XCUIElement*` on macOS | Weak on `NSStatusItem`, non-activating panels, Fn-key chords; needs Accessibility + Input Monitoring TCC pre-grants |
| **`mediar-ai/mcp-server-macos-use`** (Swift MCP server) | Promising, active 2026 | Walks `AXUIElement` trees, posts `AXPress`/`AXSetValue`; structured KB-sized AX trees instead of pixels | No assertion harness — it's a control surface, not a test framework |
| **`l-priebe/XCUITestAgent`** | Experimental, single-dev | LLM watches debug+screen state, taps elements without `accessibilityIdentifier` | Demo-quality; GPT-4o-pinned; no macOS-target story |
| **AgentSkill** (Jan 2026) | Promising SaaS | Plain-English → flake-free XCUITest **and** patches the app to add missing identifiers — closes the testability loop | iOS-focused; not validated on menu-bar/NSPanel/hotkey shapes |
| **Hammerspoon** (Lua + `hs.eventtap`) | Mature classic | Synthesizes Fn holds and Fn+key chords, drives menu-bar items, watches system events | Not LLM-aware; no assertion library; **but the only reliable Fn-chord simulator in existence** |
| Maestro, Sauce Labs, BrowserStack, TestSprite, testRigor | Mobile/web-first | — | None target macOS-app native; Sauce's Apple Silicon support is browser-only |

## What blocks "describe a flow → agent verifies it" for MacParakeet today

These are the seven concrete blockers no off-the-shelf tool solves end-to-end
in 2026:

1. **Dictation overlay is a non-activating `KeylessPanel`.** XCUITest can
   address it via the AX tree, but `canBecomeKey == false` plus
   `.activeAlways` tracking-area workarounds make SwiftUI gestures and
   inspectors flaky.
2. **Global hotkeys, especially Fn and Fn+key chords.** XCUITest cannot generate
   `CGEventTap`-level Fn presses outside the app under test. Hammerspoon's
   `hs.eventtap` is the only reliable simulator — or bind to F18/F19 via
   ADR-009 so a single keypress works.
3. **TCC bootstrapping in CI.** Microphone, Accessibility, Screen Recording,
   Input Monitoring all gate dictation + meeting recording. CI agents need a
   pre-seeded TCC.db or a signed pkg with PPPC profiles. Nothing ships this
   for you.
4. **Menu-bar-only app** (`NSStatusItem`) — Appium and Computer Use can both
   click it; Maestro/XCUITestAgent/AgentSkill don't target this surface.
5. **Snapshot drift** — `swift-snapshot-testing` is the right tool but font
   AA, locale, and animation timing differ between local Mac and CI VMs.
   Need a single dedicated runner with pinned macOS + locale + font set.
6. **Drag-drop into the file-transcription drop zone.** XCUITest's drag-drop
   is documented flaky; Appium-mac2 has open issues; AX trees expose targets
   but `NSDraggingSession` isn't fully scriptable. Hammerspoon synthesizes
   drag events; AX-tree agents can't.
7. **Audio I/O verification** — the actual point of MacParakeet. No AI
   testing framework verifies dictation produces correct text. Our existing
   `swift run macparakeet-cli transcribe` against fixtures is the right
   primitive; the gap is wiring an agent loop on top (record → transcribe →
   assert WER under threshold).

## The 2026 hybrid play

For a Mac menu-bar app with global hotkeys and non-activating panels, the AI
QA frontier is **12–18 months from a turnkey product**. The right move is a
four-layer hybrid:

1. **CLI as the primary verification surface.** `macparakeet-cli` is already
   semver-tracked (see `Sources/CLI/CHANGELOG.md`). Most behavior changes
   can be asserted headlessly through it.
2. **`swift-snapshot-testing` on a pinned CI Mac** for the design-system
   surfaces (`AssistantHead`, idle pill, dictation overlay, meetings panel).
   `MacParakeetViewModels` is already separated and snapshot-test-shaped.
3. **`mcp-server-macos-use` + Claude Code** for exploratory/dogfooding
   sessions. Closest thing to "describe a flow → agent verifies it" that
   exists for Mac native today; speaks structured AX trees instead of slow
   screenshots. ~90 minutes to wire up locally.
4. **A small Hammerspoon harness** (~200 lines of Lua + osascript) as the
   stopgap for the things AI agents can't do — Fn holds/chords, drag-drop,
   menu-bar interaction. Buys 12–18 months until native-Mac AI test agents
   mature.

## Watch list

1. **Playwright Test Agents architecture** — even though it's web-only, the
   `planner / generator / healer` shape is the cleanest 2026 design pattern.
   When porting to Mac, mirror it: an LLM that planner-explores via
   `AXUIElement` tree, generator-emits XCUITest, healer-repairs broken
   queries. Reference impl: [`microsoft/playwright-mcp`](https://github.com/microsoft/playwright-mcp).
2. **`mediar-ai/mcp-server-macos-use`** — the strongest current-day attempt.
   Track releases; bundled by Fazm v1.5.0 (Mar 27 2026).
3. **`l-priebe/XCUITestAgent`** — small enough to read in an evening.
   Pair-read with **AgentSkill**'s "patch the app to add missing
   `accessibilityIdentifier`" idea, which directly attacks our
   DesignSystem-views-have-no-IDs problem.
4. **Xcode 26 / WWDC 26 announcements.** Apple's own developments in
   parallel test suites, UI test record/replay, and on-device AI for test
   authoring will likely shift the floor.
5. **`OpenAdapt`-class record-replay tools** — when they handle window-drift
   and modal-popup recovery deterministically, the bash-and-Lua scaffolding
   in items 3–4 above collapses.

## References

- [Anthropic Computer Use docs](https://code.claude.com/docs/en/computer-use)
- [BetaAcid: experimenting with Computer Use for QA](https://betaacid.co/blog/experimenting-with-anthropics-computer-use-for-qa/)
- [Playwright Test Agents](https://playwright.dev/docs/test-agents)
- [Playwright MCP server](https://github.com/microsoft/playwright-mcp)
- [Stagehand (Browserbase)](https://www.skyvern.com/blog/browser-use-vs-stagehand-which-is-better/)
- [TestDino: Playwright AI ecosystem 2026](https://testdino.com/blog/playwright-ai-ecosystem/)
- [Schemathesis](https://schemathesis.io/)
- [swift-snapshot-testing (PointFree)](https://github.com/pointfreeco/swift-snapshot-testing)
- [SwiftUI snapshot tests pass locally / fail CI](https://dev.to/d4g4/our-swiftui-snapshot-tests-passed-locally-but-failed-on-ci-heres-the-actual-fix-5fhd)
- [`mediar-ai/mcp-server-macos-use`](https://github.com/mediar-ai/mcp-server-macos-use)
- [`l-priebe/XCUITestAgent`](https://github.com/l-priebe/XCUITestAgent)
- [AgentSkill: AI-written XCUITest](https://devshaf.medium.com/a-weekend-with-agentskill-ai-to-write-ios-uitests-26253e58862c)
- [Rainforest QA: macOS TCC.db deep dive](https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive)
- [Hammerspoon](https://www.hammerspoon.org/)
- [WWDC 25: Xcode 26 highlights](https://developer.apple.com/videos/play/wwdc2025/247/)
- [Drizz: iOS automation testing tools 2026](https://www.drizz.dev/post/ios-automation-testing-tools-in-2026)
