# WisprFlow Reverse Engineering — May 2026

> Status: **ACTIVE**. Source-of-truth teardown from reverse-engineering the installed macOS app (v1.5.308, commit `4afc9a09`). Supersedes the HISTORICAL `wisprflow-deep-dive.md` (Feb 2026, web-research-only). Companion: `wisprflow-parity-2026-05.md` maps gaps to MacParakeet.

## Method

Extracted `app.asar` from `/Applications/Wispr Flow.app` (Electron, webpack-bundled). Analyzed the main process bundle (6.8 MB), five renderer bundles (hub 11 MB, scratchpad 4.7 MB, meeting_recorder 4.6 MB, overlay 64 KB, calendar_reminder), SQLite migrations (55 files), the embedded Swift helper app (`com.electron.wispr-flow.accessibility-mac-app` v1.5.295), and the Jabra hardware SDK.

---

## Architecture

### Runtime Stack

| Layer | Technology |
|-------|-----------|
| Shell | Electron 39.8.5 (Chromium) |
| Language | TypeScript, React 18, Zustand (state) |
| Build | Webpack (electron-forge), Yarn 4 |
| Database | SQLite (better-sqlite3 + Sequelize ORM, 55 migrations) |
| Native | Swift helper app (macOS accessibility, clipboard, text insertion) |
| Audio | Opus encoding, gRPC streaming (Baseten primary) |
| Analytics | PostHog (events), Sentry (crashes) |
| Auth | Supabase |
| Backend | Baseten (STT inference), Cloudflare (CDN/gRPC proxy), custom REST API (`/llm/*`) |
| Hardware | Jabra SDK (headset wear detection, call control via BLE) |

### Process Model

```
┌──────────────────────────────────────────────────────────────────┐
│  Electron Main Process (index.js, 6.8 MB)                       │
│  ┌─────────────┐  ┌────────────┐  ┌──────────────┐             │
│  │ Audio Engine │  │ ASR Client │  │ LLM Router   │             │
│  │ (Opus enc)  │  │ (gRPC/WS)  │  │ (/llm/* API) │             │
│  └──────┬──────┘  └─────┬──────┘  └──────┬───────┘             │
│         │               │                │                      │
│  ┌──────┴───────────────┴────────────────┴──────────────┐      │
│  │  Intent Classifier (autoClassify / instructShortcut)  │      │
│  │  → dictation | instruct (ask_llm / edit_text /        │      │
│  │    draft_text / build_app)                             │      │
│  └───────────────────────────────────────────────────────┘      │
│                                                                  │
│  IPC ←→ Swift Helper (accessibility, clipboard, paste)           │
│  IPC ←→ Renderer windows (hub, overlay, scratchpad, etc.)        │
└──────────────────────────────────────────────────────────────────┘

Renderer Windows:
  ├── hub/             (11 MB)  Settings, features, insights, teams
  ├── overlay/         (64 KB)  Dictation pill UI
  ├── scratchpad/      (4.7 MB) Multi-tab notepad with voice + AI
  ├── meeting_recorder/(4.6 MB) Meeting transcription + summaries
  ├── calendar_reminder/        Meeting join/snooze notifications
  ├── contextMenu/     (4.6 MB) Right-click transforms + polish
  └── status/          (5.1 MB) Stats, leaderboards, Flow State
```

### Swift Helper App

Bundle ID: `com.electron.wispr-flow.accessibility-mac-app`

The native helper handles everything Electron can't do from a sandboxed web process:

- **Accessibility tree reading** — `AXFocusedUIElement`, `AXChildren`, `AXDescription`, `axContextV2` (HTML rendering of focused UI), `AXAttributedStringForTextMarkerRange`
- **Clipboard management** — `ClipboardMonitor`, `DelayedClipboardProvider` (delayed rendering for large pastes)
- **Text insertion** — `pasteText` with delimiters, `AXInsertStyleGroup`, insertion point tracking (`<mark class="insertion-point">`)
- **Textbox monitoring** — `_currentTextboxContents`, `afterTextBoxContents`, `_pinnedTextBox`, `_textboxMonitoringActive`
- **Focus detection** — `AXFocusedUIElementChanged`, focused app/element storage
- **IPC** — `IPCClient` communicating with the Electron main process

### STT Infrastructure

```
Primary:   gRPC → Baseten (STT inference)
Fallback:  gRPC → Cloudflare (proxy)
Fallback:  WebSocket (when gRPC fails)
External:  OpenAI Whisper API (non-English / degraded mode)
```

Audio streams in real-time via gRPC. Server monitors audio lag — if the client-sent audio is more than `MAX_SERVER_AUDIO_LAG_SECS` ahead of server-acknowledged audio, it starts a parallel HTTP fallback. The server returns word-level ASR with alignment scores, audio SNR, and volume metrics.

Geo-probing (`grpcGeoProbing`) determines the closest Baseten region.

---

## Core Feature: Intent Classification (Auto-Classify)

**This is WisprFlow's key architectural innovation.** When `isAutoInstructEnabled` is true (user preference), every dictation runs through an intent classifier:

```javascript
determineClassificationMode() {
  // Skip auto-classify if: disabled, forced instruct, forced command,
  // or app is AI/Terminal type
  return !prefs.user.internal.isAutoInstructEnabled ||
         state.isInstructMode || state.isCommandMode ||
         state.appType === AppType.AI || state.appType === AppType.Terminal
    ? state.isInstructMode && isInstructEnabled()
      ? "instructShortcut"
      : null   // plain dictation
    : "autoClassify"
}
```

### Classification Flow

1. User speaks (hold-to-talk or hands-free)
2. Audio streams to server, ASR returns `rawText`
3. If `autoClassify` mode, the server receives a `classifyIntent` call with:

```
{
  config: { dictation_short_circuit_provider, route_provider },
  routes: <available routes>,
  short_circuit_route: "dictation",  // fast-path for obvious dictation
  context: {
    asr_text: "make this more formal",
    app_name: "Slack",
    app_url: "slack.com",
    before_text: "Hey team, I wanted to...",
    selected_text: "the rough paragraph",
    after_text: "Thanks, Dan",
    ax_context: "<accessibility HTML>"
  }
}
```

4. Server classifies intent → routes to `dictation` or `instruct`
5. If `instruct`: calls `/llm/command_mode_route` (see Command Mode below)

### Route Prompt Definitions (from bundle)

The classifier has **two built-in routes** with exact prompt text extracted:

> **dictation**: *"The spoken text is plain dictation — a natural message, reply, or continuation of what is in the textbox. The text reads like something the user would type into the current app."*

> **instruct**: *"Instructed dictation — the user wants Flow to draft, compose, or edit something: 'Hey Flow, ...', 'Can you write...', 'Polish this', 'Fix the grammar'..."*

Extensions can register custom routes via `registerDictationRoute` and `modifyDictationRoute` with their own `routePrompt` and `onDictationCompleted` callbacks.

The `autoClassify` system has a `short_circuit_route` for dictation — obvious dictation is fast-pathed without full classification. Fallback for `autoClassify` is always `"dictation"`. For `instructShortcut` the fallback is `"instruct"`.

**When auto-classify is OFF** (default for new users?), the `instructShortcut` is the only way to enter command mode.

---

## Core Feature: Command Mode

When speech is classified as an instruction (or forced via `instructShortcut`), the server routes it:

```javascript
commandModeRoute(full_text, selected_text, instruction)
// POST /llm/command_mode_route
```

### Route Types

| Route | Output | What Happens |
|-------|--------|-------------|
| `ask_llm` | `ExtensionOther` | Opens **Perplexity** (`https://perplexity.ai?q=...`) in browser |
| `edit_text` | `ExtensionPaste` | Server rewrites text → pastes over selection |
| `draft_text` | `ExtensionPaste` | Server generates text → pastes at cursor |
| `build_app` | `ExtensionOther` | Opens external URL (code generation) |

### Built-in Voice Commands

Explicit voice commands bypass the LLM router entirely:

| Trigger Phrase | Action |
|---------------|--------|
| "perplexity" | Opens `perplexity.ai?q=<query>` |
| "google" | Opens `google.com/search?q=<query>` |
| "chatgpt", "chat gpt", "gpt" | Opens `chat.openai.com/?q=<query>` |
| "claude", "anthropic" | Opens `claude.ai/new?q=<query>` |
| "press enter" | Simulates Enter key (auto-submit in chat apps) |

### Instruct Mode Implementation

When the instruct route is chosen, the main process:
1. Calls `AriaWebClient.instructMode(instruction, screen_context, provider_config)`
2. Transitions the overlay to instruct mode status
3. Server processes the instruction against screen context
4. Returns result as paste or browser-open

---

## Core Feature: Polish

Polish is **separate from Command Mode** — it's a post-dictation text cleanup feature.

```javascript
AriaWebClient.polishText(...)
```

### How It Works

- Runs **after** dictation completes (not during)
- Can auto-apply or require user acceptance
- Shows diff view (`polish_diffs_shortcut`, `polish_success_diffs_clicked`)
- Has a dedicated shortcut (`polish_shortcut_used`)
- Stores results in a `polish` table (with model version, user email, prompt name, shortcut key, feedback, provider used)
- Cannot run during active dictation (`polish_disabled_during_dictation`)

### Polish API

```
POST /llm/polish_text
{
  selected_text, instructions, provider_config,
  writing_samples, custom_prompt
}
```

Models: **Claude Haiku 4.5** and **Claude Sonnet 4.5** as options.

### Polish Prompt Slots

**9 shortcut slots** (`polish_prompt_1` through `polish_prompt_9`), each bindable to a hotkey. Default prompts:
1. "Make more concise"
2. "Reword for clarity"
3. "Reorder for readability"
4. "Add structure for readability"
5. "Maintain your tone"
6. "Clarify main point"
7. "Refine phrasing for impact"

### Auto-Polish

- `autoPolishAfterDictation` setting: `{active: boolean, promptName: "polish"}`
- When active, Polish auto-runs after every dictation completes
- Shows notification: `polish_auto_edit_ready` → `accept_auto_polish_edit` / `reveal_auto_polish_edit`
- Diff view: `polish_diffs_shortcut`, `view_diff` shortcuts
- Stores both original and polished text; user can undo (`polish_undone`)
- States: `succeeded`, `long_text`, `short_text`, `timeout`, `error`, `cancelled`, `no_changes`, `not_editable`, `no_text`, `no_instructions`

---

## Core Feature: Transforms

Transforms are hotkey-triggered LLM rewrites on selected text — similar to MacParakeet's Transforms (ADR-022).

```javascript
AriaWebClient.applyTransform(...)
AriaWebClient.getTransformSuggestions(...)
```

### Where Transforms Work

| Surface | Evidence |
|---------|---------|
| System-wide (any app) | `first_transform_completed_outside_flow` |
| Meeting recorder | `meeting_transform_*` events |
| Scratchpad | `scratchpad_transform_*` events |
| Context menu (right-click) | contextMenu renderer bundle |

### Transform Flow

1. Select text in any app
2. Press transform shortcut (Opt+N)
3. Server generates rewrite
4. Result replaces selection

The context menu renderer (4.6 MB) surfaces a right-click menu with: **Polish** (AI rewrite in your voice), **Transforms** (rewrite/clean up/restructure), **Custom Prompt** (freeform), **Undo AI edit**, and **Auto-Polish toggle**. The menu label: "Configure polish, custom, and more in the Transform tab." Right-click is an alternative to hotkeys for the same underlying rewrite engine.

---

## Feature: Scratchpad

A **persistent multi-tab voice-first notepad** with AI features.

- **Tabbed interface** — Open, close, switch between notes
- **Sidebar** — Search notes, browse all
- **Version history** — Each note has versions; user can restore old versions
- **Pin notes** — Pin frequently-used notes
- **Voice input** — Dictate directly into scratchpad (primary input method)
- **AI Transforms** — Apply transforms to scratchpad text (suggestions + custom prompts)
- **Spellcheck** — In-editor spellcheck
- **Formatting** — Rich text formatting
- **Focus sessions** — `scratchpad_focus_session` (timed writing sessions?)

Data model: `notes` table (created May 2025) + `note_versions` (Mar 2026) + `note_images` (Mar 2026).

---

## Feature: Meeting Recorder

Calendar-aware meeting transcription with AI summaries.

- **Calendar integration** — `calendar:getUpcoming`, `calendar:startMeeting`, `calendar:snoozeUpcomingFromHub`, `calendar:fireNextUpcomingReminder`
- **Pre-reads** — `getCalendarEventPreread` (retrieves context about upcoming meeting before it starts)
- **Meeting summaries** — `generateMeetingSummary` (AI-generated)
- **Ask anything** — AI Q&A about meeting transcript
- **Transforms** — Apply AI transforms to meeting text
- **Audio** — AudioWorklet-based recording with mutex control, quality monitoring, mic quality warnings
- **14-day audio retention** — "Cannot download audio as it is no longer available older than 14 days"
- **Transcript** — Copy transcript, delete all transcripts
- **Calendar reminder window** — "Join meeting & open Wispr", "Just open Wispr", "Dismiss", "Remind me again in 2 minutes"

Data model: `meetings` table (Apr 2026) + `meeting_versions` (Apr 2026) + `calendar_events` (Apr 2026).

---

## Feature: Personalization System

Four independent writing style contexts:

| Context | Setting |
|---------|---------|
| Email | `personalization_email_style_set` |
| Work messages | `personalization_work_style_set` |
| Personal messages | `personalization_personal_style_set` |
| Other apps | `personalization_other_style_set` |

Each context has style variants (formal/casual/excited). Onboarding flow walks users through each context.

### Voice Profile

- **Generation** — Triggered after ~500 words dictated (`voice_profile_unlock_generation_started`)
- **Server-side** — `AriaWebClient.createVoiceProfile`, `fetchVoiceProfile`, `fetchLatestVoiceProfile`
- **Purpose** — Personalizes tone matching to the user's writing style
- **Privacy** — `insights_voice_profile_privacy_info_hovered` (users can hover for privacy info)

### Formality Detection

```javascript
AriaWebClient.detectFormality({text})
// POST /llm/detect_formality → formality_level
```

After dictation formatting, if the app is email/messaging, WisprFlow calls `detectFormality` on the user's text. It compares the detected formality level against the user's `personalizationStyles.personal` preference. On mismatch, fires a `FormalityMismatchDetected` notification (alert toast, max 5 times, 5-second timeout) with a "Disable" action. Feature flag: `StyleDetection`. Has revert function that undoes formality changes.

---

## Feature: Context Awareness

WisprFlow captures rich context from the active app to inform dictation, cleanup, and routing:

### Context Shape

```typescript
{
  appType: AI | Terminal | Browser | Chat | Email | Code | Other,
  appName: string,         // "Slack", "VS Code", etc.
  appUrl: string,          // "slack.com"
  appCodingCliAgent: string | null,  // "cline", "codex", "cursor-agent", etc.
  appCodingCliAgentConfidence: "high" | "low" | null,

  textboxContents: {
    beforeText: string,    // Text before cursor
    afterText: string,     // Text after cursor
    selectedText: string,  // Currently selected text
    contents: string,      // Full textbox contents
  },

  appContext: {
    conversationId: string,       // Chat thread ID
    nearestTexts: string,         // Nearby visible text
    axHTML: string,               // Accessibility tree as HTML
    axParsedWords: string[],      // Words from accessibility tree
    ocrParsedWords: string[],     // Words from screen OCR
    screenshot: Uint8Array | null,// Screenshot of active area
    vsCodeVariableNames: string[],// Variables from VS Code
    vsCodeFileNames: string[],    // Open files in VS Code
  },

  dictionaryContext: string[],    // User's custom dictionary words
  starredDictionaryContext: string[], // Starred (priority) dictionary words
}
```

### Screen OCR

```javascript
AriaWebClient.extractProperNounsFromScreenCapture(image)
// POST /llm/ocr — sends screenshot, returns proper nouns
```

WisprFlow takes screenshots of the active window and sends them server-side for OCR. The extracted proper nouns are added to the ASR context dictionary, improving recognition of names and jargon visible on screen.

### Textbox Monitoring

The Swift helper continuously monitors the focused text field:
- `_currentTextboxContents` — Current text in the focused field
- `_textboxMonitoringActive` — Whether monitoring is active
- `_pinnedTextBox` — Pinned text field (persists across focus changes)
- `afterTextBoxContents` — Text content after paste operation (for divergence detection)

### Edited Text Tracking

After dictation, WisprFlow tracks what the user manually edits:
- `edited_text_extracted` — System extracts user's manual edits
- `edited_text_processed` — Edits are processed for learning
- `edited_text_mismatch` / `edited_text_extract_mismatch` — Mismatch detection

This feeds back into personalization — WisprFlow learns from how users correct its output.

---

## Feature: Dictionary & Snippets

### Dictionary

- Personal + Team dictionaries (team requires Pro/Enterprise)
- Auto-add from corrections (`dictionary_item_auto_added`)
- Starred entries (higher priority in ASR context)
- Bulk import (`dictionary_bulk_import_*`)
- Server sync (`AriaWebClient.getUserDictionary`, `updateUserDictionary`, `getTeamDictionary`)
- "To-replace" entries (misspelling → correction, added Mar 2026)

### Snippets

- Trigger phrase → expansion text
- Personal + Team
- Bulk import (`snippets_bulk_import_*`)
- Added Aug 2025

---

## Feature: Popo (Hands-Free / Tap Dictation)

**"Popo" is WisprFlow's internal name for their hands-free / tap-to-activate voice mode**, distinct from PTT (push-to-talk / hold-to-talk).

| Mode | Trigger | Behavior |
|------|---------|----------|
| PTT (push-to-talk) | Hold Fn | Hold to record, release to transcribe |
| Popo (tap-to-talk) | Fn+Space (macOS) / Ctrl+Win+Space (Windows) | Tap to start, tap to stop |

The state machine tracks `ACTIVE_PTT` and `ACTIVE_POPO` as parallel states with separate debounce logic (`DebouncePTT` vs `DebouncePOPO`). The `transcriptCommand` column categorizes recordings as `"ptt"` or `"popo"` (or `"lens"` or `"command"`).

Onboarding A/B tests `PttFirst` vs `PopoFirst` ordering. Feature flags: `try-popo-onboarding`, `SuggestPOPO`. Discovery nudge appears as a "Tip" badge.

---

## Feature: Focus Mode

- Blocks specified apps and URLs during focus sessions
- Toggle via Opt+F
- `focus_mode_activated`, `focus_mode_deactivated`, `focus_mode_blocked`
- Can block specific apps or URLs (configurable list)

---

## Feature: Auto Cleanup

Multiple cleanup levels applied to all dictations:

- `auto_cleanup_level_changed` — User changes cleanup intensity
- `auto_cleanup_configure_clicked` — Opens configuration
- `auto_cleanup_diff_clicked` — View before/after diff
- `auto_cleanup_completed` — Applied to dictation
- `auto_cleanup_nudge_shown` — Discovery notification

Levels appear to be: None / Light / Medium / High (from parity doc observation).

---

## Feature: Press Enter Command

Voice command that auto-submits text in chat applications:

- `press_enter_command_prompt` — Prompt asking user to enable/disable
- `enable_press_enter_command` / `disable_press_enter_command`
- Say "press enter" at the end of dictation → simulates Enter key

---

## Feature: Email Signature

Appends "Spoken with Wispr Flow" or "Written with Wispr Flow" to emails:

- **Options**: `WrittenWithFlow` (default) or `SpokenWithFlow`
- **Hyperlink variant**: Wraps "Wispr Flow" in an `<a>` tag pointing to the user's referral URL
- **Eligibility**: Only fires for email apps (`appType === Email`), user must have >1 and <100 email words
- **Pipeline step**: `EMAIL_SIGNATURE` runs alongside `TRANSCRIBE → ALIGN → FORMAT → LOWERCASE_SENTENCES → SLACK_TAGGING`
- Feature flag: `EmailSignature` with `HyperlinkOn` variant

---

## Feature: Mouse Flow

Mouse-activated dictation (alternative to keyboard shortcuts):

- `mouse_flow_banner_*` — Discovery banner
- `mouse_flow_setup_completed` — Setup flow
- `mouse_flow_discovery_*` — Feature introduction
- `mouse_flow_walkthrough_step` — Guided walkthrough
- `mouse_flow_homepage_banner_dismissed` — Homepage promotion

---

## Feature: Flow Bar

Draggable floating dictation indicator:

- `flow_bar_dragged` / `flow_bar_dropped` — User repositions the bar
- `flow_bar` — The persistent floating UI element
- Always-visible option in settings (`Show Flow bar at all times`)

---

## Feature: IDE Integrations

### Cursor & Windsurf

File-aware formatting for AI coding IDEs:

- **File tagging** (`ideFileTagging`, default `true`): Extracts filenames from the IDE's accessibility context, caches them (`cursorFileNames` map, overflow warning at >100 files), uses fuzzy matching to format `@filename` references correctly
- **Formatting**: `cursorFormatting` handles `@` mentions, `{{TAB}}` tokens, and `{{BREAK}}` markers for IDE-specific paste behavior
- **IDE screen reader mode**: Reads `ideScreenReaderMode` for accessibility
- Feature flag: `cursor-integration`

Apps classified as "AI" type (special formatting rules): ChatGPT, Claude, Cursor, Windsurf, VS Code, Perplexity, Warp, Ghostty.

### Coding CLI Agent Detection

Feature flag: `coding-cli-detection`. Detects AI coding agents in terminals:

```javascript
CodingCLIAgent: ["aider", "claude", "cline", "codex", "cursor-agent",
                  "gemini", "opencode", "qwen"]
CodingCLIAgentConfidence: ["high", "low"]
```

Tracks `lastCodingCliAgent` and `lastCodingCliAgentConfidence` in state. When detected, adjusts formatting for code-heavy dictation.

### MCP Integration (Claude Desktop Extension)

The app bundles `wispr-flow.mcpb` — a **zip-packaged DXT (Desktop Extension)** containing a self-contained Python MCP server (`flow_mcp_server.py`, 938 lines, zero dependencies). It reads/writes WisprFlow's local `flow.sqlite` database via stdio JSON-RPC 2.0.

**6 MCP tools exposed to Claude Desktop / Claude Code / Cursor:**

| Tool | Access | Description |
|------|--------|-------------|
| `search_scratchpad_notes` | Read | Search notes |
| `get_scratchpad_note` | Read | Get note by ID |
| `create_scratchpad_note` | Write | Create new note |
| `update_scratchpad_note` | Write | Edit existing note |
| `search_meetings` | Read | Search meeting transcripts |
| `get_meeting` | Read | Get meeting with transcript (`[timestamp] Speaker: text`) |

Also exposes MCP resources at `scratchpad://note/{id}` and `meeting://meeting/{id}`. Built with `@anthropic-ai/mcpb` (DXT bundler). All data stays local — no network calls. One-click "Install for Claude" flow from the app.

---

## Feature: Team & Enterprise

- **Team dictionary** — Shared vocabulary across team members
- **Team leaderboards** — Weekly rankings by word count (`teamleaderboardhistoryclicked`, `teamleaderboardpagination`, `teamleaderboardsortby`)
- **Team invites** — Invite links, join requests, bulk invites, self-invite
- **Enterprise** — `enterprise_blocked`, `enterprise_ip_blocked`, IP allowlisting
- **HIPAA BAA** — `signHipaaBaa`, `getHipaaBaaStatus` — healthcare compliance
- **Admin portal** — `team_admin_portal_opened`, manage members, billing
- **Rank celebrations** — Gamified notifications for leaderboard placement

---

## Feature: Insights & Gamification

- **Usage heatmap** — `insights_heatmap_cell_hovered`, `insights_heatmap_navigated`
- **Corrections info** — `insights_corrections_info_hovered`
- **Word count breakdown** — `insights_total_words_breakdown_hovered`, `insights_total_words_change_hovered`
- **Voice profile** — Generated from insights, visualized in the insights page
- **Share** — Share stats to LinkedIn, X, or download (`insights_share_*`)
- **Daily streaks** — `daily-streak` feature flag
- **Flow State** — Year-in-review / wrapped-style feature

---

## Feature: Calendar Integration

- `CalendarEvent` table (Apr 2026)
- `syncCalendar` — Sync calendar events from connectors
- `listConnectorCalendarEvents` — List upcoming events
- `getCalendarEventPreread` — AI pre-reads meeting context before it starts
- `manualCalendarResync` — Force refresh
- Calendar reminder window: "Meeting starting" → Join, Open Wispr, Dismiss, Snooze 2 min

---

## Feature: Links (Clipboard Tracking)

A clipboard link tracker that enriches copied URLs:

- Tracks `firstCopiedAt`, `lastCopiedAt`, `copyCount` per URL
- Enriches with fetched HTML title and anchor text
- Pin frequently-used links
- Domain-level grouping

---

## Feature: Jabra Hardware Integration

Full Jabra SDK integration (`@gnaudio/jabra-js`):

- **Wear detection** — `jabra-wear-detection` feature flag
- **BLE audio** — Bluetooth Low Energy microphone input (`BLEAudioData`, `ble-mic-ring`)
- **Call control** — Answer/reject/mute via headset buttons
- **Device connector** — Native binary for device communication
- **Link quality monitoring** — `bluetoothLinkQuality`

---

## App Detection Registry

WisprFlow has bundle-ID-level detection for 50+ apps, enabling per-app behavior:

| Category | Apps |
|----------|------|
| **Browsers** | Chrome, Arc, Safari, Brave, Firefox |
| **AI/LLM** | ChatGPT, Claude, Perplexity, Gemini, DeepSeek, Mistral, Poe, Grok |
| **IDEs** | VS Code, Cursor, Windsurf, JetBrains, Replit, Trae |
| **Terminals** | Terminal, Warp |
| **Chat** | Slack, Discord, WhatsApp, Telegram, Messages, Messenger, Beeper |
| **Email** | Gmail, Outlook, Superhuman, Apple Mail |
| **Docs** | Google Docs, Notion, Obsidian, Apple Notes, Word |
| **Productivity** | Linear, Figma, Miro, Asana, Trello, ClickUp, Airtable |
| **Office** | Excel, PowerPoint, OneNote |
| **Social** | LinkedIn, X/Twitter, Instagram |
| **Video** | Zoom, Google Meet |
| **Calendar** | Google Calendar |
| **Storage** | Google Drive |
| **Meta** | Wispr Flow itself, GitHub, Raycast |

Each app has `bundleIds` (macOS process detection) and optional `url` (browser tab detection) and `windowsUri` (Windows protocol handler).

### App Type Classification

Apps are classified into types that affect routing behavior:

- `AI` — ChatGPT, Claude, Perplexity, etc. → auto-classify disabled (always dictation)
- `Terminal` — Terminal, Warp → auto-classify disabled
- Other types inferred: Browser, Chat, Email, Code, Other

---

## Database Schema (55 migrations, SQLite via Sequelize)

### Tables

**`dictionary`** (May 2024) — Custom vocabulary + snippets in one table.
PK: `phrase`. Columns: `lastUsed`, `lastSeen`, `frequencyUsed`, `frequencySeen`, `manualEntry` (bool), `isSnippet` (bool), `isStarred` (bool), sync fields.

**`history`** (May 2024) — Dictation records. 30+ columns accumulated over 2 years.
PK: `transcriptEntityId` (UUID). Key columns:
- **Text variants**: `asrText`, `formattedText`, `editedText`, `toneMatchedText`, `pastedText`, `defaultAsrText`, `fallbackAsrText`, `defaultFormattedText`, `fallbackFormattedText`
- **Context**: `app`, `url`, `textboxContents`, `micDevice`, `language`, `conversationId`, `axText` (accessibility), `axHTML`
- **Media**: `audio` (blob), `builtInAudio` (blob), `screenshot` (blob), `opusChunks`
- **Metrics**: `e2eLatency`, `numWords`, `duration`, `speechDuration`, `numWordsCorrected`, `numDictionaryReplacements`, `formattingDivergenceScore`, `timezoneOffsetMinutes`
- **Learning**: `editedTextStatus` (NOT_EXTRACTED / EXTRACTED / EMPTY / SEMANTIC_DIFFERENCE / ERROR / PROCESSING), `editedTextAttempts`, `toneMatchPairs` (JSON), `feedback`
- **State**: `status`, `shareType`, `needsUploading`, `isArchived`, `appVersion`

**`polish`** (Jan 2026) — Transform/rewrite history.
PK: `id` (UUID). Columns: `polishInitialText`, `polishedText`, `polishInitialWordCount`, `polishedWordCount`, `app`, `processingTime`, `status` (10 states incl. `no_changes`, `not_editable`, `cancelled`), `polishUndone`, `instruction`, `modelVersion`, `diffCount`, `feedback`, `usedProvider`, `promptName`, `shortcutKey`, `needsUploading`.

**`notes`** (May 2025) — Scratchpad notes.
PK: `id` (UUID). Columns: `title`, `content`, `contentPreview`, `searchableContent`, `finalized`, `pinned`, `synced`, `isDeleted`.

**`note_versions`** (Mar 2026) — Version history for notes.
FK to notes. Columns: `content`, `source`, `transformId`, `transformPrompt`.

**`note_images`** (Mar 2026) — Inline note images.
FK to notes. Columns: `data` (blob), `width`, `height`, `sizeBytes`.

**`meetings`** (Apr 2026) — Meeting recordings.
PK: `id` (UUID). Columns: `title`, `content`, `contentPreview`, `transcript` (TEXT, JSON array of `{entryKind, text, timestamp, speaker}`), `summary`, `finalized`, `synced`, `isDeleted`.

**`meeting_versions`** (Apr 2026) — Meeting note version history.
FK to meetings. Columns: `content`, `source`, `transformId`, `transformPrompt`.

**`calendar_events`** (Apr 2026) — Calendar sync for meeting reminders.
PK: `externalId`. Columns: `title`, `startAtUtc`, `endAtUtc`, `conferenceUrl`, `status`, `notifiedAt`, `summary`, `prereadTitle`, `prereadContent`. Indexed for "due reminder" queries. Pre-reads are generated ~22hrs before meeting start.

**`links`** (Apr 2026) — Clipboard link tracking with enrichment.
PK: `url`. Columns: `domain`, `title`, `pinned`, `firstCopiedAt`, `lastCopiedAt`, `copyCount`, `title_source`, `anchor_text_raw`, `fetched_html_title`, `enrichment_attempted`, `enrichment_status`.

**`snippets`** (Aug 2025) — Text expansion triggers.
Separate from dictionary despite similar functionality.

**`notifications`** (Apr 2025) — Remote notification cache.
Standard id/type/key/title/text/isRead/isArchived.

### Notable Schema Signals

- **Screenshots stored as blobs** alongside dictation audio — they capture and persist visual context
- **A/B fallback ASR** — `defaultAsrText` vs `fallbackAsrText` (two parallel STT paths, best one wins)
- **Formatting divergence score** — Measures how much the user's actual paste differed from the AI-formatted text
- **Tone match pairs** (JSON) — Stores style transfer examples for personalization learning
- **Edited text status** with attempt tracking — Systematic learning from user corrections
- **Polish `promptName` + `shortcutKey`** — Confirms user-assignable transform shortcuts (same direction as our ADR-022)
- **Calendar pre-read content** — AI generates meeting prep 22 hours before start

---

## AriaWebClient API Surface

The full server API (108 methods discovered):

### STT & ASR
- `warmup` — Pre-warm the ASR connection
- `transcribeOpenAI` / `transcribeOpenAIAudioChunks` — OpenAI Whisper fallback

### Intent Classification & Routing
- `classifyIntent` — Classify speech as dictation or instruction
- `commandModeRoute` — Route instruction to handler (ask_llm, edit_text, draft_text, build_app)
- `instructMode` — Execute instruct mode with screen context

### Text Processing
- `polishText` — Post-dictation AI cleanup
- `applyTransform` / `getTransformSuggestions` — Transform text
- `detectFormality` — Detect tone mismatch
- `extractProperNouns` — Extract names from textbox text
- `extractProperNounsFromScreenCapture` — OCR + noun extraction from screenshot
- `extractEditedWords` — Learn from user corrections
- `formatNonEnglish` — Multilingual formatting
- `checkSensibility` — Validate output sensibility

### Dictionary & User
- `getUserDictionary` / `updateUserDictionary` — Personal dictionary
- `getTeamDictionary` / `addTeamDictionaryWord` / `updateTeamDictionaryWord` / `deleteTeamDictionaryWord` — Team dictionary
- `bulkCreateTeamDictionaryItems` — Bulk team dictionary import
- `getUserPreferences` / `updateUserPreferences` — User settings
- `getUserStats` / `overwriteUserStats` — Usage statistics
- `updateUserProfile` — Profile updates
- `applyDesktopWordsCorrectedBackfillDelta` — Backfill corrections

### Voice Profile
- `createVoiceProfile` / `fetchVoiceProfile` / `fetchLatestVoiceProfile`

### Meeting
- `generateMeetingSummary`
- `syncMeetings` / `syncNotes`

### Calendar
- `syncCalendar` / `listConnectorCalendarEvents` / `manualCalendarResync`
- `getCalendarEventPreread`

### Insights
- `getInsightsHeatmap` / `getInsightsStats`

### Connectors
- `getConnectors` / `initiateConnectorConnection` / `rawExecuteConnectorTool`

### Account & Billing
- `getSubscription` / `getCheckoutSessionUrl` / `getCustomerPortalUrl`
- `createEnterpriseCheckoutSession` / `createEnterpriseNew` / `getEnterprise`
- `applyPromoCode` / `applyReferralCode` / `getReferralsInfo` / `regenerateReferralCode`
- `claimTrialExtension`
- `deleteAccount`

### Team
- `acceptTeamInviteLink` / `inviteToTeam` / `sendInvites` / `getTeamMembers`
- `acceptJoinRequest` / `bulkAcceptJoinRequest` / `deleteJoinRequest`
- `getTeamInviteLink` / `getTeamInvitations` / `revokeInvitation`
- `contactTeamAdmins` / `getEnterpriseUserStats` / `getEnterpriseWeeklyRanks` / `getEnterprisePodiums`

### Auth & Device
- `registerDevice` / `getRegisteredDevices` / `pollDeviceCode`
- `createAndSignInSandboxUser` / `destroySandboxUser`
- `checkEligibility` / `getGeoRegion` / `getDomainInfo`
- `pricingByIp` / `trackPaywallViewed`

### HIPAA
- `signHipaaBaa` / `getHipaaBaaStatus`

### Misc
- `getGrpcServerList` — Get available gRPC endpoints
- `reportTranscript` — Report problematic transcript
- `sendUserFeedback` / `sendPreLoginFeedback`
- `uploadHistory` / `uploadPolish` / `checkSync`
- `completion` — LLM completion endpoint
- `getContext` — Get server-side context
- `sendMobileDownloadLink` / `inviteSelf`

---

## Pricing & Tiers

| Tier | Limits | Features |
|------|--------|----------|
| Free (Basic) | 2,000 words/week | Dictation, basic cleanup |
| Pro | Unlimited | Command Mode, Polish, Transforms, Personalization, Insights, Voice Profile |
| Enterprise | Unlimited | Team dictionary, leaderboards, HIPAA BAA, admin portal, IP allowlisting |
| Trial | 14 days Pro | Full Pro features |

Referral program: 1 month Pro per successful referral.

---

## Supported Languages

From the code: `en-US`, `en-GB`, `es-ES`, `fr-FR`, `de-DE`, `ja-JP`, `ko-KR`, `zh-CN`, `pt-BR` (9 explicit). Marketing claims "99 languages" with auto-detect. Server-side ASR likely supports more via the Whisper fallback path.

---

## Feature Flags (from overlay bundle)

```
auto-cleanup-v0
auto-polish-on-short-text
ax-context-v2
instruct-mode
coding-cli-detection
daily-streak
focus-change-detector
jabra-wear-detection
ble-mic-ring
```

---

## Text Processing Pipeline

The server-side processing pipeline has named stages:

```
TRANSCRIBE → ALIGN → FORMAT → LOWERCASE_SENTENCES → SLACK_TAGGING → EMAIL_SIGNATURE
```

Plus post-pipeline steps: `detectFormality`, `extractProperNouns` / `extractProperNounsFromScreenCapture`, `extractEditedWords`, `toneMatch`.

### Transcript Command Types

Every dictation is categorized by input mode:

| Command | Mode |
|---------|------|
| `ptt` | Push-to-talk (hold shortcut) |
| `popo` | Tap-to-talk (hands-free) |
| `lens` | Flow Lens (unknown — possibly visual/screenshot-based dictation?) |
| `command` | Command Mode (instruction) |

### Slack Tagging

`SLACK_TAGGING` — When dictating in Slack, auto-formats @mentions. The pipeline reads `axParsedWords` from the accessibility context to identify Slack usernames and channels, then formats `@name` references correctly.

---

## Key Architectural Takeaways for MacParakeet

### What WisprFlow Does That We Don't

1. **Auto-classify intent** — Automatic dictation vs. instruction routing. This is the big one. Users don't need a separate shortcut to enter command mode — the system figures it out from context.

2. **Rich screen context** — Accessibility tree, OCR, screenshots, VS Code variable names. All sent server-side for contextual ASR and instruction routing.

3. **Per-app behavior** — 50+ app detections with type classification. Changes tone, formatting, and routing per app.

4. **Voice Profile** — Server-generated writing persona from usage data. Personalizes all AI output.

5. **Personalization styles** — Four context-specific writing styles (email/work/personal/other).

6. **Edited text learning** — Tracks user corrections, feeds back into personalization.

7. **Scratchpad** — Persistent multi-tab notepad with voice input and version history.

8. **Team/Enterprise** — Shared dictionary, leaderboards, HIPAA, admin portal.

9. **Jabra hardware** — Headset wear detection and BLE mic support.

10. **Server-side polish with diff review** — Shows before/after diff; user accepts or undoes.

### What They Do That We Intentionally Skip

- **Cloud STT** — We're local-first (Parakeet ANE). They stream everything to Baseten.
- **Cloud LLM for all text** — Every dictation touches their server for cleanup, context, tone matching.
- **Accounts & auth** — We have no accounts. They require Supabase login.
- **Team features** — Solo-focused vs. enterprise.

### Architectural Differences

| | WisprFlow | MacParakeet |
|---|-----------|-------------|
| **Runtime** | Electron + Swift helper | Native Swift (SwiftUI + AppKit) |
| **STT** | Cloud (Baseten gRPC, Whisper fallback) | Local (Parakeet ANE, WhisperKit optional) |
| **LLM** | Cloud (proprietary, server-side) | User's provider (OpenAI, Anthropic, local) |
| **Text insertion** | Clipboard paste via Swift helper | Clipboard paste via ClipboardService |
| **Context** | AX tree + OCR + screenshots → server | None (local only, no screen reading) |
| **Database** | SQLite (better-sqlite3 + Sequelize) | SQLite (GRDB) |
| **State** | Zustand | SwiftUI @Observable |
| **Updates** | Electron auto-update | Sparkle |
| **Bundle size** | ~250 MB (Electron + Chromium) | ~100 MB (native + CoreML models separate) |

---

*Reverse-engineered 2026-05-13 from WisprFlow v1.5.308 (macOS). Raw extracted asar at `/tmp/wispr-flow-asar/`.*
