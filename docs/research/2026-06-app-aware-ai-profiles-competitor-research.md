# App-Aware AI Profiles Research - June 2026

> Freshness stance: existing MacParakeet docs and older branches are historical
> inputs only. This packet prioritizes current `origin/main`, fresh GitHub issue
> state, and fresh external repo/product research gathered on 2026-06-03.

Related GitHub issues:

- `#117` - app detection and profiles for app-specific AI summary/settings.
- `#412` - custom prompt based on focused app.

## Executive Summary

The market has moved past a single global dictation cleanup prompt. The strongest
current pattern is an explicit profile or workflow object that matches the
current app and, in more mature products, the active browser hostname. The
profile can then override prompt/style, language, engine, provider/model,
formatting, and send behavior.

For MacParakeet, the right first slice is narrower:

- Add app-aware profiles for the opt-in Dictation AI Formatter.
- Match exact bundle ID first, then coarse local app category, then the existing
  global AI Formatter prompt.
- Keep exact bundle IDs, app display names, profile IDs/names, and profile
  match kinds local in V1. Telemetry continues to emit only the existing coarse
  app category.
- Do not ship browser hostname matching in v1. Plan it as a second slice with
  parsed-host matching and explicit Apple Events/privacy UX.
- Reuse the existing Transform app-context machinery later; do not revive the
  old transform-only ADR unchanged.

This solves the user-visible examples from `#117` and `#412` without turning the
first release into a full workflow engine.

## Current MacParakeet Baseline

Fresh local inspection of `origin/main` at `05055bc8` found:

- Dictation AI Formatter has one global prompt in runtime preferences. It is
  injected as a no-argument closure from `AppEnvironment` into
  `DictationService`.
  - `Sources/MacParakeet/App/AppEnvironment.swift`
  - `Sources/MacParakeetCore/Services/Dictation/DictationService.swift`
  - `Sources/MacParakeetCore/TextProcessing/AIFormatter.swift`
- Dictation already samples the frontmost app near stop/undo time for
  privacy-safe telemetry category. This is the right lifecycle moment for
  paste-target prompt selection.
  - `Sources/MacParakeet/App/DictationFlowCoordinator.swift`
  - `Sources/MacParakeetCore/Services/Telemetry/TelemetryAppCategory.swift`
- Transform selection capture already returns exact local app context through
  `SelectionCaptureTarget`. Transform history stores source app bundle/name
  locally, while telemetry sends only a coarse `app_category`.
  - `Sources/MacParakeetCore/Services/System/SelectionCaptureService.swift`
  - `Sources/MacParakeetCore/Services/Transforms/TransformExecutor.swift`
  - `Sources/MacParakeet/App/TransformsCoordinator.swift`
- Prompt source scoping exists, but it is transcription-source scoping
  (`meeting`, `file`, etc.), not app-context scoping.
  - `Sources/MacParakeetCore/Models/Prompt.swift`
  - `Sources/MacParakeetCore/Database/PromptRepository.swift`

Implication: MacParakeet already has the local app-category privacy contract and
most of the app-context plumbing. The missing feature is deterministic prompt
resolution before AI formatting.

## Internal Prior Art

An older branch, `feat/transforms-per-app-variants`, contains a transform-only
proposal:

- `plans/active/2026-05-transforms-phase-3-per-app-variants.md`
- `spec/adr/023-transforms-per-app-variants.md`

Useful ideas:

- Deterministic transform lookup: `appVariants[bundleID] ?? content`.
- CLI forcing for tests/provisioning: `--for-app`, `--app-variant`.
- Browser limitation named honestly: browser bundle IDs identify Chrome/Safari,
  not Gmail/X/Notion tabs.
- Telemetry flag only: whether an app variant was used, never the bundle ID.

Stale pieces to supersede:

- The proposed `v0.14` migration number is stale; `main` already uses v0.14 for
  Transform history and v0.20 for source-scoped prompt auto-run.
- Do not add a new `CaptureContext`; `SelectionCaptureTarget` already exists
  and is tested.
- The old plan assumes the coordinator captures before executor run. On current
  `main`, `TransformExecutor` owns capture, so Transform prompt resolution must
  happen inside/alongside executor after capture or via a resolver callback.
- The old ADR is Transform-specific and does not cover Dictation AI Formatter,
  which is the first useful vertical slice for `#117`.

## External Research

### TypeWhisper

Fresh repo inspected: `TypeWhisper/typewhisper-mac`
`main@f5b55f9083a66f93911c6ddf49539c7b1e5094a5`.

Public docs: <https://www.typewhisper.com/en/docs/mac/workflows/>

Current shape:

- Active concept is `Workflow`, not a separate prompt/rule pair.
- Workflows can trigger by website, app, hotkey, manual palette, or fallback.
- Workflows can override language, engine/model, task, prompt, LLM
  provider/model, output format, auto-submit, and priority.
- Automatic match order in docs is website, app, then always fallback.
- The active workflow badge shows which workflow matched and why.
- Website matching normalizes domains and matches subdomains such as
  `gist.github.com` for `github.com`.
- App-aware formatting can be deterministic and bundle-ID based; known apps map
  to Markdown, HTML, Code, Plain Text, or fallback.

Implementation findings from fresh code read:

- Runtime captures `NSWorkspace.shared.frontmostApplication` after audio capture
  starts, then asynchronously resolves browser URL.
- Browser URL resolution supports Safari, Arc, and Chromium-family browsers;
  Firefox returns no URL.
- Fresh code inspection found a more specific internal order than the public
  docs summarize: app+website, website-only, app-only, then global fallback.
- Final processing waits for URL resolution so URL-specific workflow overrides
  can apply.

Lessons:

- Profiles should be first-class records with trigger, behavior, and output
  fields.
- Match explanations matter. The user should know why a profile applied.
- Browser hostname matching is valuable but should be separate from v1 because
  it adds Apple Events, browser-specific behavior, and URL normalization.

### VoiceInk

Fresh repo inspected: `Beingpax/VoiceInk`
`main@0df2a9ab4de28c684d6fbff77686807abb14f876`.

Docs:

- <https://tryvoiceink.com/docs/power-mode>
- <https://tryvoiceink.com/docs/contextual-awareness>

Current shape:

- The feature is centered on Power Modes.
- Each Power Mode stores app bundle triggers, website triggers, transcription
  model/language, formatting cleanup, AI enhancement, selected prompt, AI
  provider/model, screen context, auto-send, enabled/default flags, and optional
  shortcut.
- Runtime routing checks the frontmost app, tries browser URL matching first,
  falls back to bundle-ID matching, then default mode.
- Applying a mode snapshots current global settings, mutates them for the
  session, and restores after recording depending on the persistence setting.
- Prompt routing is separate: trigger words can temporarily choose a prompt and
  strip the trigger from the utterance.
- Contextual awareness can add selected text, clipboard, and one-time OCR of
  the active window into the AI prompt.

Important caution:

- Website matching is loose substring matching after stripping protocol and
  `www.`. That creates false-positive risk. MacParakeet should parse URLs,
  normalize hosts, and match host suffixes if/when browser domains ship.

Lessons:

- Profiles should choose defaults for a context; manual/voice prompt overrides
  are a different axis.
- Temporary profile application versus persistent setting changes must be
  explicit and tested.
- Screen/clipboard/selected-text context is powerful, but should be a later
  opt-in step because it expands privacy surface area.

### Handy

Fresh repo inspected: `cjpais/handy`
`main@10a4c31b361722602676105a641a0ddb2fc7612d`.

Current shape:

- Handy has a global post-processing prompt/provider/model configuration.
- It has no app-aware profile system, no frontmost bundle routing, and no
  browser/domain matching in the inspected current code.
- Runtime supports normal transcription and `transcribe_with_post_process`.

Lesson:

- Handy is a useful baseline for "global prompt only", which is exactly the
  limitation the MacParakeet issues are asking to move past.

### OpenWhispr

Fresh repo inspected: `OpenWhispr/openwhispr`
`main@38e832d23dbd1da472a331a9262106a8e9ba9b01`.

Current public shape:

- Cross-platform voice-to-text with local/cloud engines, AI agents, meeting
  transcription, notes, and APIs.
- Public README emphasizes dictation into any app and privacy-first operation.
- Current prompt registry separates cleanup, dictation agent, note formatting,
  and chat intelligence scopes.
- Routing is voice-invoked by agent-name detection, not app context.

Second repo inspected: `MrPrinceRawat/OpenWhispr`
`main@2f2a6175766a4903590b4f469ad9759465bc1179`.

- This project has a simple per-bundle tone override. Active app bundle ID
  selects a tone such as casual, neutral, professional, or raw.
- It does not do browser/domain routing.

Lesson:

- OpenWhispr's main repo is useful for prompt-scope separation; the
  MrPrinceRawat fork is useful evidence that bundle-ID-only tone routing is a
  viable small slice.

### FluidVoice

Fresh repo inspected: `altic-dev/FluidVoice`
`main@7793fbd80972ef340d3f5f65ff12c789036d8c11`.

Current shape:

- Has prompt profiles plus `AppPromptBinding`.
- Routing scope can be all apps or selected apps only.
- Active app is captured before overlays change focus.
- Prompt resolution can select app-bound prompts and fall back to defaults.
- Browser/window-title heuristics exist in older/commented code but are not an
  active domain-matching system at this ref.

Lesson:

- Exact bundle prompt binding is enough to ship a useful app-specific prompt
  feature.
- Capture timing must be tested around overlays and focus changes; app context
  capture can be correct in principle but wrong in practice if MacParakeet
  itself becomes frontmost.

### Yapper

Fresh repo inspected: `ahmedlhanafy/yapper`
`main@c668397077289f66c4a69ea404ae032afeed5b14`.

Current shape:

- Has custom modes with AI instructions, provider/model, context toggles, and
  mode-cycling hotkeys.
- Captures clipboard, selected text, active app, window title, and browser URL
  as prompt context.
- Automatic app/website activation appears unimplemented despite profile-like
  fields.

Lesson:

- "Context in the prompt" and "context used for routing" are different systems.
  MacParakeet should implement deterministic routing first, not rely on the LLM
  to infer style from injected app context.

### Anarlog / Hyprnote / Char

Fresh repo inspected: `fastrepl/anarlog`
`main@0bf4f4c5bb64bff68776a016fffb660f9900d548`.

Current shape:

- Hyprnote now resolves to Anarlog. Char's current codebase does not appear to
  be public; Anarlog's README says Char is a separate current product.
- Prompt templates are operation-scoped: enhance, chat, title,
  transcript-patch, activity-capture, and daily-summary.
- Meeting enhancement templates serialize typed context: session,
  participants, transcript, pre-meeting memo, post-meeting memo, and template
  sections.
- Template choice is global/default plus manual per-enhanced-note. Suggested
  templates are ranked from meeting title, notes, and transcript content.
- Screen context capture and Chrome Meet native-host context exist, but current
  prompt routing is meeting-template oriented, not app-aware dictation routing.

Lesson:

- Meeting templates and dictation profiles should remain separate. Meeting
  prompts are transcript/participants/notes oriented; dictation profiles are
  short rewrite/format instructions bound to a paste target.
- Persisting chosen template/profile ID with generated output is a strong
  provenance pattern.

### Hex

Fresh repo inspected: `kitlangton/Hex`
`main@f988cb78c57f206abd6935ff93042242fc7669ad`.

Current shape:

- Captures `NSWorkspace.shared.frontmostApplication` at dictation recording
  start.
- Transcript history stores `sourceAppBundleID` and `sourceAppName`; the UI
  displays app icon/name.
- Current customization is global deterministic post-processing. No current LLM
  prompt/profile layer was found.

Lesson:

- App provenance in history is valuable even before routing exists.
- Capture-at-start is a useful reliability reference, but MacParakeet's paste
  target model still needs stop/undo-time context or a documented fallback when
  focus drifts.

### Whispur and Pindrop

Sources:

- Whispur: <https://whispur.app/>
- Pindrop: <https://github.com/watzon/pindrop>

Current shape:

- Both support system-wide dictation and optional AI cleanup.
- Whispur exposes custom prompt presets but no confirmed app-aware profile
  routing in the inspected public docs.
- Pindrop exposes optional AI enhancement and app-context adapter files in the
  repo shape, but the public README is not a stronger profile pattern than
  TypeWhisper or VoiceInk.
- Whispur's cleanup prompt/settings are a useful safety pattern: frame cleanup
  as text transformation and require output-only behavior, rather than letting
  the model answer or execute dictated content.

Lesson:

- These reinforce that optional AI cleanup is mainstream, but not the strongest
  source for app-aware profile requirements.

### Wispr Flow

Source: <https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles>

Current shape:

- Flow Styles let users pick tone per app category: Personal messages, Work
  messages, Email, and Other.
- The docs frame it as "pick a tone for each kind of app" and verify by
  dictating in an app in that category.
- Styles are currently English-only and gradually rolled out.

Lesson:

- Category defaults are product-friendly and easier than exact-app rules for
  casual users.
- MacParakeet should support local category profiles, but preserve the existing
  global prompt as fallback and avoid turning on surprise rewrites by default.

### Raycast Dictation

Source: <https://manual.raycast.com/ai/dictation>

Current shape from broader research:

- Raycast combines global instructions, vocabulary, style prompts, and app
  context for AI dictation.
- It offers built-in Email/Messaging styles and custom styles mapped to apps or
  websites.

Lesson:

- Built-in style templates help onboarding, but MacParakeet should keep them as
  creation templates or explicit opt-ins so the local-first default remains
  unchanged.

### Superwhisper

Source: <https://superwhisper.com/docs/modes/custom>

Current shape:

- Custom modes support AI instructions.
- Context awareness has separate toggles for application context, copied text,
  and selected text.
- Prompting docs name separate content channels: `User Message`,
  `Application Context`, `Selected Text`, and `Clipboard Context`.

Lesson:

- Prompt inputs should be structured and explicit. Do not silently stuff
  clipboard/screen/selection context into a profile. If MacParakeet adds these
  later, each source needs its own opt-in.

### MacWhisper

Source: <https://macwhisper.helpscoutdocs.com/article/31-app-specific-dictation-prompts>

Current shape:

- App Specific Dictation Prompts let users add running apps and choose prompts
  from their dictation prompt list.
- The support page names use cases: translation for a specific chat app, code
  editor prompting, and professional email wording.

Lesson:

- The simplest useful feature is exact app -> prompt for dictation. This is
  enough to address the MacParakeet issues without browser/domain matching.

### Amical

Source: <https://amical.ai/docs/personalisation>

Current shape:

- Personalization is organized as built-in default skills plus user custom
  skills.
- Skills target desktop apps and websites, with editable polishing level, tone,
  app/site lists, and preset selection.
- Custom prompts are shown as planned but disabled in that build.
- Matching picks the first custom skill, otherwise the matching default,
  otherwise a default catch-all.

Lesson:

- Built-in defaults plus custom overrides is a strong product shape.
- MacParakeet can start with custom profiles and templates, then decide later
  whether category defaults should auto-apply.

### Espanso

Source: <https://espanso.org/docs/configuration/app-specific-configurations/>

Current shape:

- App-specific configs combine filters and options.
- Configs inherit default options unless they override specific fields.
- On macOS, app identifier is a stable matching input. Window title can match
  browser tabs but is explicitly less stable.
- Only one app-specific config applies at a time; precedence is documented.

Lesson:

- Keep matching deterministic and explainable.
- Stable app identity should be preferred over window title or inferred text.
- Inheritance from the global default is easier to debug than independent
  profiles that duplicate every setting.

## Primary Source Links

External code and docs used in this packet:

- TypeWhisper workflows docs:
  <https://www.typewhisper.com/en/docs/mac/workflows/>
- TypeWhisper workflow model and matching:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/f5b55f9083a66f93911c6ddf49539c7b1e5094a5/TypeWhisper/Models/Workflow.swift>
  and
  <https://github.com/TypeWhisper/typewhisper-mac/blob/f5b55f9083a66f93911c6ddf49539c7b1e5094a5/TypeWhisper/Services/WorkflowService.swift>
- TypeWhisper app/browser detection:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/f5b55f9083a66f93911c6ddf49539c7b1e5094a5/TypeWhisper/Services/TextInsertionService.swift>
- VoiceInk Power Mode docs:
  <https://tryvoiceink.com/docs/power-mode>
- VoiceInk context awareness docs:
  <https://tryvoiceink.com/docs/contextual-awareness>
- VoiceInk Power Mode code:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/PowerModeConfig.swift>
  and
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/ActiveWindowService.swift>
- VoiceInk browser URL and AI enhancement code:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/BrowserURLService.swift>
  and
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/Services/AIEnhancement/AIEnhancementService.swift>
- Handy settings/actions:
  <https://github.com/cjpais/handy/blob/10a4c31b361722602676105a641a0ddb2fc7612d/src-tauri/src/settings.rs>
  and
  <https://github.com/cjpais/handy/blob/10a4c31b361722602676105a641a0ddb2fc7612d/src-tauri/src/actions.rs>
- FluidVoice app prompt binding and resolution:
  <https://github.com/altic-dev/FluidVoice/blob/7793fbd80972ef340d3f5f65ff12c789036d8c11/Sources/Fluid/Persistence/SettingsStore.swift>
- Yapper context capture and prompt injection:
  <https://github.com/ahmedlhanafy/yapper/blob/c668397077289f66c4a69ea404ae032afeed5b14/Sources/Yapper/Core/Context/ContextCapture.swift>
  and
  <https://github.com/ahmedlhanafy/yapper/blob/c668397077289f66c4a69ea404ae032afeed5b14/Sources/Yapper/Core/AI/AIProcessor.swift>
- Anarlog meeting template/context code:
  <https://github.com/fastrepl/anarlog/blob/0bf4f4c5bb64bff68776a016fffb660f9900d548/crates/template-app/src/enhance.rs>
  and
  <https://github.com/fastrepl/anarlog/blob/0bf4f4c5bb64bff68776a016fffb660f9900d548/packages/store/src/zod.ts>
- Hex dictation app metadata:
  <https://github.com/kitlangton/Hex/blob/f988cb78c57f206abd6935ff93042242fc7669ad/Hex/Features/Transcription/TranscriptionFeature.swift>
  and
  <https://github.com/kitlangton/Hex/blob/f988cb78c57f206abd6935ff93042242fc7669ad/HexCore/Sources/HexCore/Models/TranscriptionHistory.swift>
- Wispr Flow styles:
  <https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles>
- Superwhisper custom modes/context:
  <https://superwhisper.com/docs/modes/custom>
- MacWhisper app-specific dictation prompts:
  <https://macwhisper.helpscoutdocs.com/article/31-app-specific-dictation-prompts>
- Amical personalization:
  <https://amical.ai/docs/personalisation>
- Espanso app-specific configuration:
  <https://espanso.org/docs/configuration/app-specific-configurations/>

## Pattern Taxonomy

### Matching Inputs

Lowest-risk now:

- Exact macOS bundle ID.
- Coarse local category (`messaging`, `email`, `browser`, `notes`, `docs`,
  `code`, `terminal`, `other`).
- Existing global fallback.

Second slice:

- Browser hostname/domain, using parsed URL host suffix matching.
- Requires Apple Events/browser scripting UX and explicit privacy copy.

Later opt-in:

- Selected text context.
- Clipboard text context.
- One-time active-window OCR/screen context.
- Voice trigger words.

Avoid for v1:

- Window title matching.
- Loose substring URL matching.
- Sending bundle IDs, hostnames, selected text, clipboard, or screen context to
  telemetry.

### Profile Fields

Common fields across competitors:

- Name and enabled state.
- Trigger list: apps, domains, hotkeys, fallback.
- Prompt/style behavior.
- Language/STT engine overrides.
- LLM provider/model overrides.
- Output formatting.
- Auto-submit/send key behavior.

MacParakeet v1 should include only:

- Name.
- Enabled state.
- Match target: exact app bundle or coarse category.
- Prompt template.
- Sort/display metadata.
- Optional built-in creation template.

Everything else can stay global until a real user need justifies another axis.

### Context Capture Timing

Competitors split between start-time capture and just-after-start capture:

- TypeWhisper captures the active app after audio capture starts, so app lookup
  does not delay the first words.
- FluidVoice captures active app before overlays change focus.
- Hex captures frontmost app at recording start and persists it as history
  metadata.
- MacParakeet currently refreshes app category near stop/undo time to reflect
  the paste target.

Recommended MacParakeet stance:

- Use stop/undo-time context for v1 prompt resolution because it matches the
  existing paste-target telemetry model.
- Also test focus drift explicitly. If stop/undo-time context is missing or is
  MacParakeet itself, fall back to a start-time snapshot captured before any
  MacParakeet UI can become frontmost.
- Record which local context source was used for debugging, but do not send the
  exact app or source decision to telemetry.

### Matching Order

Recommended MacParakeet v1:

1. Explicit exact-bundle profile.
2. Coarse app-category profile.
3. Existing global AI Formatter prompt.

Recommended future with browser domains:

1. Explicit manual/profile hotkey override.
2. App+hostname profile.
3. Hostname-only profile.
4. Exact bundle profile.
5. Coarse app-category profile.
6. Existing global prompt.

## Recommended Product Direction

### First Release

Build Dictation AI Formatter profiles.

The user can add a profile for Slack, Mail, Terminal, Cursor, etc., or for a
coarse category like Email or Terminal. If AI Formatter is enabled and the
focused paste target matches the profile at stop/undo time, MacParakeet uses
that profile's prompt. If focus has drifted to MacParakeet or the context is
unknown, the runtime can fall back to a start-time snapshot. Otherwise it uses
the existing global prompt.

The app should make the match explainable, at least in settings preview and
local debug/history metadata. Telemetry stays coarse.

### Second Release

Add browser hostname matching if the first release proves useful.

The implementation must parse URLs, normalize the host, strip a leading `www.`,
and match exact host or subdomain suffix. It should not use substring matching.
The user should see a clear permission/privacy explanation before browser URL
access is enabled.

### Third Release

Add Transform per-app variants using the same context matcher service, while
keeping the Transform prompt variant storage attached to each Transform prompt.
The old transform-only ADR can be rewritten as an implementation ADR once the
shared matcher exists.

## Open Questions

- Should category profiles ship as disabled templates, enabled defaults, or not
  at all? The conservative answer is disabled templates.
- Should exact-app profiles be limited to one per bundle ID? The conservative
  answer is yes for v1.
- Should matched profile name appear in dictation history? It improves
  debuggability, but adds schema fields. The implementation plan includes this
  because competitors show visible match badges and users need to trust routing.
- Should profile prompt selection also apply to file transcription? No for v1.
  File transcription has no paste target, so app-aware routing is not meaningful
  without a separate "source profile" concept.
