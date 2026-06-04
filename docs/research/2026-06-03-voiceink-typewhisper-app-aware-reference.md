# VoiceInk and TypeWhisper App-Aware Dictation Reference

Date: 2026-06-03

Scope: focused read of two open-source macOS dictation projects for lessons on
app-aware AI formatter/profile design in MacParakeet.

Source refs:

- VoiceInk: `Beingpax/VoiceInk@0df2a9ab4de28c684d6fbff77686807abb14f876`
  - Repo: <https://github.com/Beingpax/VoiceInk>
  - Power Mode docs: <https://tryvoiceink.com/docs/power-mode>
- TypeWhisper: `TypeWhisper/typewhisper-mac@7c2abcb7b6c9485459f71c262bdb0a72a7801b1f`
  - Repo: <https://github.com/TypeWhisper/typewhisper-mac>
  - README workflow summary: <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/README.md#L82-L96>

## VoiceInk

### Architecture

VoiceInk is a native SwiftUI macOS app organized by folders rather than by
separate package targets. The relevant boundaries are `Transcription`,
`PowerMode`, `Services/AIEnhancement`, `Paste`, `Models`, and Settings views.

The app-aware system is `PowerMode`. It is broader than MacParakeet's current AI
Formatter profiles: a Power Mode can override transcription model, language,
AI enhancement, selected prompt, AI provider/model, screen context, formatting,
auto-send behavior, enabled state, default state, and shortcuts.

Key source anchors:

- Power Mode config model and manager:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/PowerModeConfig.swift#L23-L41>
- Active app/browser matching:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/ActiveWindowService.swift#L22-L67>
- Session-scoped apply/restore:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/PowerModeSessionManager.swift#L43-L96>
- AI enhancement prompt/context service:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/Services/AIEnhancement/AIEnhancementService.swift#L145-L201>

### Flow

VoiceInk starts recording first, then applies the Power Mode after audio capture
is live. The start flow creates a recording file, buffers early chunks, starts
the recorder, applies app/URL profile settings, then prepares streaming model
callbacks.

Matching order:

1. If the frontmost app is a supported browser, get the current URL by
   AppleScript and match URL profiles.
2. If no URL profile matched, match by app bundle identifier.
3. If no app profile matched, use the configured default mode.

The transcription pipeline then transcribes, applies formatting and replacement
steps, optionally detects spoken prompt trigger words, optionally runs AI
enhancement, pastes, optionally auto-sends, and saves history.

Key source anchors:

- Recording start applies Power Mode after audio starts:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/Transcription/Engine/VoiceInkEngine.swift#L133-L223>
- Pipeline paste and auto-send:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/Transcription/Engine/TranscriptionPipeline.swift#L216-L237>
- Browser URL service:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/BrowserURLService.swift#L96-L146>

### Schema And Persistence

VoiceInk stores Power Modes as JSON-encoded Codable structs in `UserDefaults`
under `powerModeConfigurationsV2`. The active config ID is a separate
`UserDefaults` key. That is simple, but it is not a model MacParakeet should
copy because MacParakeet already has GRDB migration discipline and user-data
tables.

`PowerModeConfig` fields:

- `id`, `name`, `emoji`
- `appConfigs: [AppConfig]?`, with bundle ID and app name
- `urlConfigs: [URLConfig]?`, with normalized URL/domain strings
- AI enhancement enabled, selected prompt, selected AI provider/model
- selected transcription model/language
- formatting flags: paragraph formatting, punctuation cleanup, lowercase
- screen context, auto-send key, enabled/default flags

Custom prompts are also JSON in `UserDefaults`. Predefined prompts are merged
into the persisted list; users can only customize trigger words for predefined
system prompts.

History records keep Power Mode provenance (`powerModeName`,
`powerModeEmoji`) alongside transcription metadata.

Key source anchors:

- Power Mode JSON persistence:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/PowerModeConfig.swift#L175-L206>
- Prompt persistence:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/Services/AIEnhancement/AIEnhancementService.swift#L16-L102>
- Prompt model:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/Models/CustomPrompt.swift#L78-L134>
- History Power Mode metadata:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/Transcription/Engine/VoiceInkEngine.swift#L388-L414>

### UI/UX

VoiceInk treats Power Mode as an advanced separate workspace. It has Add,
Reorder, enable toggles, Default badges, emoji identity, app/website summary
chips, and compact row chips for model/language/AI/prompt/context/auto-send.

The editor groups controls into General, Trigger Scenarios, Transcription,
collapsible Transcript Formatting, AI Enhancement, and Advanced. Apps are picked
from an icon/search app picker. Websites are entered manually as strings.

This is good for power users, but it is too much for MacParakeet's first
app-aware AI Formatter release. The UI lesson is not "copy Power Mode"; it is
"keep simple defaults up front and put override creation behind progressive
disclosure."

Key source anchors:

- Power Mode list page:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/PowerModeView.swift#L62-L209>
- Row summary chips:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/PowerModeViewComponents.swift#L152-L322>
- Editor sections:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/PowerModeConfigView.swift#L176-L527>
- App picker:
  <https://github.com/Beingpax/VoiceInk/blob/0df2a9ab4de28c684d6fbff77686807abb14f876/VoiceInk/PowerMode/AppPicker.swift#L3-L79>

### VoiceInk Lessons

- Borrow session-scoped profile application as a concept, but do not mutate
  global settings just to choose a formatter prompt.
- Borrow row-level summary chips, app picker, enable/default badges, and
  progressive disclosure.
- Borrow local provenance: profile name/origin is useful for trust and support.
- Do not borrow loose URL substring matching. Future browser support should parse
  URLs, normalize hosts, and match exact host or subdomain suffix.
- Do not borrow `UserDefaults` JSON as the durable profile store.
- Keep selected text, clipboard, and screen OCR as separate opt-in context
  sources. They are not required for prompt routing.

## TypeWhisper

### Architecture

TypeWhisper is a native macOS menu-bar app with a large `ServiceContainer`
singleton wiring services, view models, plugins, hotkeys, workflow support, and
recorder support. It is more plugin-oriented and singleton-heavy than
MacParakeet's Core/ViewModels/App split, so the domain ideas are more valuable
than its dependency shape.

Its current first-class app-aware concept is `Workflow`, not just "profile".
A workflow can have triggers plus behavior/output overrides. There is also a
legacy `Profile` model with similar rule-matching behavior.

Key source anchors:

- App wiring:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/App/TypeWhisperApp.swift#L150-L210>
- Service container:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/App/ServiceContainer.swift#L8-L65>
- Plugin SDK README:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisperPluginSDK/Plugins/README.md#L12-L21>

### Flow

TypeWhisper intentionally starts audio capture before heavier context work. Once
recording is live, it captures the active app, stores app metadata, and resolves
browser URL asynchronously. If URL resolution finds a more specific workflow,
the active workflow is updated while recording continues.

On stop, TypeWhisper drains audio, classifies edge cases, transcribes, runs an
ordered post-processing pipeline, then inserts text or dispatches an action
plugin. Text insertion prefers Accessibility replacement when possible and
falls back to clipboard paste with pasteboard tagging, verification, optional
clipboard restore, and optional Enter.

Key source anchors:

- Start recording, then capture context:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/ViewModels/DictationViewModel.swift#L929-L948>
- Async browser URL resolution and workflow update:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/ViewModels/DictationViewModel.swift#L980-L1035>
- Post-processing and insertion:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/ViewModels/DictationViewModel.swift#L1267-L1340>
- Text insertion:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Services/TextInsertionService.swift#L418-L499>

### Schema And Persistence

TypeWhisper's `Workflow` is a SwiftData `@Model` stored in `workflows.store`.
The schema uses top-level columns for identity/order plus encoded payloads for
trigger, behavior, and output.

Workflow schema highlights:

- `id`, `name`, `isEnabled`, `sortOrder`, `templateRaw`
- `triggerKindRaw`, `triggerData`
- legacy trigger columns: `triggerAppBundleIdentifier`,
  `triggerWebsitePattern`, `triggerHotkeyData`
- `behaviorData`, `outputData`
- `createdAt`, `updatedAt`

`WorkflowTrigger` is structured and supports app, website, hotkey, global, and
manual triggers. It stores arrays for apps, websites, and hotkeys. This is a
good future-proof shape if MacParakeet grows beyond exact app/category prompts.

`WorkflowBehavior` stores prompt/LLM/transcription overrides. `WorkflowOutput`
stores output format and auto-enter behavior.

Matching order:

1. App plus website
2. Website only
3. App only
4. Global fallback

Ties are resolved by sort order/name for workflows. The legacy profile service
uses priority/name.

TypeWhisper also has `AppFormatterService`, a small deterministic mapping from
known bundle IDs to output formats like markdown, HTML, code, or plaintext.
That is directly relevant to MacParakeet's "sensible defaults for common apps"
direction.

Key source anchors:

- Workflow trigger model:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Models/Workflow.swift#L139-L281>
- Workflow behavior/output/model:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Models/Workflow.swift#L283-L514>
- Workflow persistence store:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Services/WorkflowService.swift#L75-L100>
- Workflow matching:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Services/WorkflowService.swift#L224-L282>
- App formatter known mappings:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Services/AppFormatterService.swift#L6-L66>
- Legacy profile model:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Models/Profile.swift#L4-L89>
- Legacy profile matching:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Services/ProfileService.swift#L162-L202>

### UI/UX

TypeWhisper has the strongest UI lesson: make rules readable in plain language.
The legacy profiles UI shows an active rule banner and rows that narrate the
match and behavior as "When context X, use behavior Y". The editor is a
three-step wizard: Scope, Behavior, Review.

Useful UX patterns:

- Separate "where should this apply?" from "how should it respond?"
- App picker uses installed app names/icons rather than asking for bundle IDs
  first.
- Website scope is optional, contextual, and can use the current detected domain.
- The UI explains subdomain matching.
- Review step previews the rule before saving.
- Advanced controls are grouped after the core scope/behavior choices.
- Workflow templates give users a concrete starting point.

Key source anchors:

- Rules page header, empty state, active rule banner:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Views/ProfilesSettingsView.swift#L45-L97>
- Row narrative and prompt chip:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Views/ProfilesSettingsView.swift#L221-L333>
- Three-step editor:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Views/ProfilesSettingsView.swift#L381-L536>
- Scope step:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Views/ProfilesSettingsView.swift#L618-L708>
- Website scope and subdomain explanation:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Views/ProfilesSettingsView.swift#L795-L899>
- Behavior step:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/Views/ProfilesSettingsView.swift#L904-L1097>
- Rule narration helpers:
  <https://github.com/TypeWhisper/typewhisper-mac/blob/7c2abcb7b6c9485459f71c262bdb0a72a7801b1f/TypeWhisper/ViewModels/ProfilesViewModel.swift#L638-L820>

### TypeWhisper Lessons

- Borrow deterministic specificity: app+website, website, app, fallback for
  future browser support. For MacParakeet V1, use exact app, category, built-in
  category default, global.
- Borrow plain-language match explanations. Users should see why a prompt will
  apply without reading a precedence table.
- Borrow "current app/domain" affordances and installed-app picker UI.
- Borrow structured trigger payloads if MacParakeet later grows profiles beyond
  a prompt override.
- Borrow source-code app mappings for common apps/categories.
- Do not borrow the large plugin/workflow scope for this first feature.
- Do not borrow destructive store recovery. MacParakeet should keep migration-safe
  GRDB persistence.

## Best Lessons For MacParakeet

Recommended V1 shape:

1. Keep the product surface narrow: AI Formatter profiles select a formatter
   prompt only. Do not add STT engine, language, LLM provider/model, auto-send,
   screen context, or clipboard context yet.
2. Use sensible built-in category defaults in source code, not persisted rows.
   Users should only persist custom overrides.
3. Resolver order should be deterministic and test-covered:
   exact custom app profile, custom category profile, built-in category default,
   global prompt.
4. The default UI should show "Smart defaults" as simple category chips, not a
   prompt editor. Custom profiles belong behind "Advanced custom profiles".
5. Exact app profile creation should start from an app picker or "Use current
   app" action. Raw bundle ID entry should be secondary.
6. Add match preview language. Good UI copy shape: "Current target: Slack uses
   Messaging smart default." For an override: "Current target: Mail uses Email
   custom profile."
7. Store built-in profile origin separately from custom profile origin. The
   runtime/debug view should be able to say whether a match came from a custom
   profile, built-in default, or global fallback.
8. Keep browser hostname matching out of V1. When added, use structured trigger
   data and host suffix matching, not substring matching.
9. Keep telemetry privacy-bounded. Exact bundle IDs, profile IDs, hostnames,
   prompt text, clipboard, selected text, and screen context stay local. Existing
   coarse category telemetry is enough.
10. Do not delay audio start for app/URL/context detection. For formatter prompt
    resolution, use the paste target context if reliable and keep a start-time
    fallback for cases where focus drifts to MacParakeet UI.

## Concrete Follow-Ups

These are the refinements suggested by the research after the current
MacParakeet smart-default implementation:

- Add a small "current target preview" row in the AI Formatter settings.
- Add installed-app picker support before exposing manual bundle IDs.
- Expand the bundle-to-category map for common apps: Slack, Messages, Discord,
  Teams, Mail, Outlook, Gmail-in-browser as future hostname support, Notes,
  Notion, Obsidian, Bear, Google Docs/Microsoft Word as future hostname/app
  support, Xcode, VS Code, Cursor, Zed, Terminal, iTerm.
- Keep the default smart category prompts non-editable at first. Editing should
  create a custom category override.
- Add local provenance fields or debug metadata before broadening routing:
  matched profile name, match kind, profile origin, and fallback reason.
