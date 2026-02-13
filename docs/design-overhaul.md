# MacParakeet UI/UX Design Overhaul

> Status: **ACTIVE** — Design specification for v1.0 shipping UI

## Locked Decisions

These were discussed and finalized. Don't revisit.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pill / overlay | **UNTOUCHED** | Already excellent. Zero changes to DictationOverlayView, IdlePillView, or their controllers. |
| Theme default | **Light** | Consumer apps default light. Dark available as option. |
| Accent color | **Coral-orange** | Parakeet plumage, stands out from blue/purple competitors, warm and inviting. |
| Sound design | **Custom sounds** | Plan now, implement with UI overhaul. Ship everything together. |
| Sonic mandala | **Thumbnails everywhere** | Monochrome in lists, full color in detail view. Subtle, not overwhelming. |
| Drop zone | **Portal effect** | Dramatic, memorable. Particles + gravity + glow on file enter. |
| Creative vision | **Full** | All-in on warm magical. No half measures. |
| Merkaba (main window) | **State-reactive** | Responds to transcription state (processing/done/idle). NOT voice-reactive (that's the pill's job). |

---

## The Problem

MacParakeet currently has a **Pro/Technical** aesthetic: dark-only theme, low-opacity text (`.tertiary`, `.quaternary`), dense layouts, small type, dashed borders, sacred geometry as cold mathematical ornament. This is the visual language of Xcode, Logic Pro, and Terminal.

Our customer at $49 one-time purchase is a **journalist, student, podcaster, content creator, or knowledge worker**. The current UI says "this is a tool for engineers" when it should say "this is magic, and anyone can use it."

### Current UI Audit

| Screen | Issues |
|--------|--------|
| **Transcribe** | Dashed-border drop zone feels like a code editor; format list (MP3, WAV...) reads like a spec sheet; cramped "or" divider; UUID filenames in recent list |
| **Dictations** | Flat list with tiny timestamps looks like a log viewer; no visual personality; cold empty state |
| **Vocabulary** | Dense form with pipeline steps reads like a README; `.caption` tips barely readable |
| **Settings** | Standard macOS Form — functional but cold; no warmth |
| **Onboarding** | Best of the bunch — structured flow, clear CTAs — but feels like Setup Assistant, not a welcome |

### What Works (Untouched)

- **Dictation pill + overlay** — Excellent. Zero changes.
- **Idle pill** — Perfect. Zero changes.
- **Bottom bar player** in Dictations — Good pattern, keep.
- **Sidebar navigation** — Standard macOS pattern, don't fight it.

---

## Design Direction: "Warm Magical"

**One line**: An app that feels like it was designed for someone who's never used a transcription tool, wrapped in a creative, slightly magical personality.

### Design Spectrum

```
Pro/Technical ←———→ Apple Native ←———→ Warm Minimal ←——→ Bold Consumer
(Xcode, Logic)    (Notes, Finder)   (Things 3, Bear)   (Arc, CleanShot)
                                           ↑
                                   MacParakeet lands here
                                   with Bold personality →
```

**Inspiration**: Things 3 (spacious simplicity), Bear (warm personality), Craft (premium feel), Arc (bold identity), CleanShot X (confident color)

### Core Principles

1. **"UI for 5-year-olds"** — If a 5-year-old can figure out the primary action, the design is right. Big targets, obvious affordances, zero cognitive load.
2. **Warm, not cold** — Soft off-whites, warm coral accent, rounded typography. Nothing feels clinical.
3. **Personality in the quiet moments** — Empty states, loading, success — these are where delight lives.
4. **Less text, more visual** — Replace format lists with implied affordance. Replace pipeline steps with visual flow. If you're reading, you're not doing.
5. **Light by default** — Dark mode is an option, not the identity.
6. **Every voice leaves a mark** — The sonic mandala: each recording generates a unique visual fingerprint.

---

## Color System

### Light Theme (Default)

```
Background:           #FAFAF8  (warm off-white, NOT pure white)
Surface:              #FFFFFF  (cards, panels)
Surface Elevated:     #F5F5F0  (sidebar, secondary panels)

Primary Text:         #1A1A1A  (near-black, high contrast)
Secondary Text:       #6B6B6B  (descriptions, metadata)
Tertiary Text:        #9B9B9B  (timestamps, hints — use sparingly)

Accent:               #E86B3A  (warm coral-orange — the "parrot" color)
Accent Light:         #FFF0EB  (tinted backgrounds, hover states)
Accent Dark:          #C45428  (pressed states)

Success:              #34A853  (warmer green)
Warning:              #F5A623  (amber)
Error:                #E54D42  (warm red)

Border:               #E8E8E0  (warm gray border)
Divider:              #F0F0E8  (barely-there divider)
```

### Dark Theme (Option)

```
Background:           #1C1C1E  (Apple dark, not pure black)
Surface:              #2C2C2E
Surface Elevated:     #3A3A3C

Primary Text:         #FFFFFF
Secondary Text:       #A1A1A6
Tertiary Text:        #636366

Accent:               #FF8A5C  (lighter coral for dark backgrounds)
Accent Light:         rgba(255,138,92,0.12)

Success:              #4ADE80  (brighter green for dark)
Warning:              #FBBF24
Error:                #F87171
```

### Why Coral-Orange?

- **Parakeet = tropical bird** — warm, vibrant plumage. Coral is literally the color of a sun parakeet.
- **Competitive differentiation**: WisprFlow uses purple, MacWhisper uses blue, Superwhisper uses system blue. Nobody owns warm orange in this space.
- **Warmth** — Coral is one of the friendliest colors. It says "creative" and "approachable."
- **Sacred geometry pairing** — Golden light + geometry = mystical warmth rather than cold technicality.

---

## Typography

```swift
enum Typography {
    // Headlines — .rounded design = instantly warmer
    static let heroTitle    = Font.system(size: 28, weight: .bold, design: .rounded)
    static let pageTitle    = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)

    // Body — larger minimums than current
    static let bodyLarge    = Font.system(size: 15)     // primary reading text
    static let body         = Font.system(size: 14)     // standard body
    static let bodySmall    = Font.system(size: 13)     // secondary info

    // Metadata
    static let caption      = Font.system(size: 12)     // timestamps, badges
    static let micro        = Font.system(size: 11)     // barely used, minimum allowed

    // Monospace
    static let timestamp    = Font.system(size: 12).monospacedDigit()
    static let duration     = Font.system(size: 11).monospacedDigit()
}
```

**Rules**:
- Nothing below 11pt anywhere in the app
- `.quaternary` foreground style is **banned** — lowest is `.tertiary`, used sparingly
- `.rounded` design for all headlines (heroTitle, pageTitle)

---

## Spacing

More generous than current developer-dense values.

```swift
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16    // was 12
    static let lg: CGFloat = 24    // was 16
    static let xl: CGFloat = 32    // was 24
    static let xxl: CGFloat = 48   // was 40
    static let hero: CGFloat = 64  // new: empty states, hero areas
}
```

---

## Layout

```swift
enum Layout {
    static let sidebarMinWidth: CGFloat = 200      // was 180
    static let contentMinWidth: CGFloat = 500      // was 400
    static let windowMinHeight: CGFloat = 560      // was 520
    static let cornerRadius: CGFloat = 16          // was 12
    static let cardCornerRadius: CGFloat = 14      // was 10
    static let rowCornerRadius: CGFloat = 12       // was 8
    static let dropZoneCornerRadius: CGFloat = 20  // new: large, friendly
    static let buttonCornerRadius: CGFloat = 12    // new
    static let minTouchTarget: CGFloat = 44        // Apple HIG minimum
}
```

---

## Sonic Mandala — The Signature Feature

Every transcription and dictation generates a **unique circular waveform pattern** — a sonic mandala. This is MacParakeet's visual signature. No other transcription app does this.

### What It Is

A circular visualization derived from actual audio data. Think of it as a voice fingerprint — each recording produces a distinct radial pattern based on amplitude, frequency, and rhythm. Two recordings of the same text will look different because the voice is different.

### Generation Algorithm

```
Input: WordTimestamp[] (already stored per transcription/dictation)
Process:
  1. Sample N points from word-level amplitudes (confidence scores as proxy)
  2. Map to radial distances from center
  3. Apply smooth interpolation (Catmull-Rom or similar)
  4. Mirror for symmetry (optional — test both asymmetric and symmetric)
Output: Array of radial values → drawn as a circular path
```

The data is already available — `WordTimestamp` has `confidence` scores per word. We just need to visualize them as a circular pattern.

### Appearance

| Context | Size | Style | Color |
|---------|------|-------|-------|
| Dictation list row | 32pt | Monochrome, single stroke | Accent coral at 0.3 opacity |
| Transcription list row | 32pt | Monochrome, single stroke | Accent coral at 0.3 opacity |
| Transcription result (hero) | 120pt | Full color, filled, gradient | Coral → gold gradient, soft glow |
| Dictation detail (if opened) | 80pt | Full color, filled | Accent coral, warm center |

### In Lists (Monochrome)

- Replaces the current icon squares (32×32 colored rectangles with SF Symbols)
- Each mandala is unique to that recording
- Subtle, not distracting — think of it like a contact photo but generated from voice
- Single-color stroke (accent at low opacity) on transparent background
- Fallback for recordings without word data: simple concentric circle pattern

### In Detail View (Full Color)

- Large hero element above the transcript
- Warm coral-to-gold gradient fill
- Soft outer glow
- Optional: subtle rotation animation (very slow, 20s+)

### Quality Bar

The mandala must look **beautiful at 32pt**. If it looks noisy, blobby, or indistinguishable at small size, it's wrong. Test criteria:
- Two different recordings must be visually distinguishable at 32pt
- The pattern must be smooth (no jagged edges)
- It must feel organic, not mathematical
- It should look intentional, not like a bug

---

## Portal Drop Zone — The Hero Interaction

The file drop zone is the first thing users see. It should feel like **dropping a file into a portal**, not dragging it into a box.

### Idle State

- Large warm card (not a dashed border) with `Surface Elevated` background (#F5F5F0 light / #3A3A3C dark)
- State-reactive merkaba floating at center (80pt, slow 6s rotation, accent coral tint)
- **"Drop a file to transcribe"** — heroTitle font, centered below merkaba
- **"or Browse Files"** — secondary text, clickable, underlined on hover
- No format list. No technical details.
- Soft rounded corners (20pt radius)
- Subtle shadow to lift it off the background

### Hover State (File Dragging Over)

- Card **lifts** — shadow grows (radius 8 → 16, y offset 4 → 8)
- Background brightens to `Accent Light` (#FFF0EB)
- Border appears in accent color (1pt, accent at 0.4)
- Merkaba **accelerates** — rotation speed doubles (6s → 3s)
- Merkaba **brightens** — center glow intensifies, vertex dots pulse
- Subtle **particle drift** — 6-8 tiny dots float upward from the card edges, accent colored, 0.3 opacity

### File Dropped (Processing Starts)

- Card smoothly transitions to the transcribing state
- Merkaba enters fast spin (2s) with progress ring
- Particles converge toward center (gravity effect)
- The portal "closes" — card contracts slightly before expanding into the progress view

### YouTube URL Section

- Separate card below the drop zone (not inside it)
- Same warm styling — `Surface Elevated` background, rounded corners
- YouTube icon (play.rectangle) in accent color
- Clean text field with subtle border
- Arrow button in accent color when URL is valid
- No "or" divider between cards — visual separation is enough

---

## Sacred Geometry Evolution

The merkaba evolves from "subtle tech ornament" to "warm magical companion" in the main window. (Stays white/monochrome in the dictation pill — that's untouched.)

### Current State

- Very subtle (0.06 opacity strokes, 0.15 opacity fill)
- Monochrome (`.primary` — white in dark, black in light)
- Small (40-64pt)
- Feels mathematical

### New Direction (Main Window Only)

- **Warm-tinted** — Accent coral with golden center glow
- **Larger** — 80-120pt for hero uses
- **More alive** — Warm light bloom at center, vertex dots glow
- **State-reactive** — Speed and brightness respond to app state
- **Still elegant** — "Mystical compass," not "cartoon mascot"

### State Reactions

| App State | Merkaba Behavior |
|-----------|-----------------|
| Idle (empty state) | Slow rotation (6s), gentle pulse, warm coral at 0.3 |
| File hovering | Accelerates (3s), brightens to 0.6, subtle particles |
| Transcribing | Fast rotation (2s), bright accent, progress ring around it |
| Download in progress | Medium rotation (3.5s), cool-blue tint shift |
| Complete | Brief golden bloom, then settles to idle |
| Error | Dims, slight red tint, then recovers |

### Particle System (New Component)

Subtle particle effects for the merkaba in hero contexts:

- **Count**: 6-12 particles max (not a firework, a shimmer)
- **Motion**: Slow upward drift or orbital float around merkaba
- **Size**: 2-3pt dots
- **Color**: Accent at 0.2-0.4 opacity
- **When**: Drop zone hover, onboarding hero, transcription complete
- **Performance**: Only render when visible, disable for reduced motion accessibility

---

## Sound Design

MacParakeet ships with custom audio feedback. No other transcription app has crafted sound design — this is pure edge.

### Sound Palette

The overall tone is **warm, organic, slightly mystical**. Think singing bowls, soft chimes, subtle tones. NOT notification bleeps, NOT game sounds.

| Event | Sound Character | Duration | Notes |
|-------|----------------|----------|-------|
| Recording start | Soft ascending chime — like tapping a small singing bowl | 300-500ms | Plays when Fn double-tap starts recording |
| Recording stop | Gentle descending tone — the bowl settling | 200-400ms | Plays when Fn stops recording |
| Transcription complete | Warm "ding" — a bell with slow decay | 400-600ms | Success moment, should feel satisfying |
| File dropped into portal | Soft whoosh + subtle crystal tone | 300-500ms | Accompanies the portal animation |
| Error | Low, muted tone — not alarming, just "hmm" | 300ms | Should not startle |
| Copy to clipboard | Tiny click/snap — barely there | 100ms | Haptic-feeling, optional |

### Design Constraints

- **Always optional** — Respect macOS "Play sound effects" system setting
- **Never startling** — Max volume is 30-40% of system alert volume
- **Unique to MacParakeet** — These sounds should be recognizable as ours
- **Short** — Longest sound is 600ms. This is feedback, not music.
- **High quality** — 48kHz, clean recordings. No cheap synth.

### Asset Format

- `.aif` or `.wav` format (macOS native, no decoding overhead)
- Bundled in app resources
- Named: `record_start.aif`, `record_stop.aif`, `transcription_complete.aif`, `file_dropped.aif`, `error_soft.aif`, `copy_click.aif`

### Implementation

```swift
// SoundManager.swift — new file
import AVFoundation

enum AppSound: String {
    case recordStart = "record_start"
    case recordStop = "record_stop"
    case transcriptionComplete = "transcription_complete"
    case fileDropped = "file_dropped"
    case errorSoft = "error_soft"
    case copyClick = "copy_click"
}

// Play via AVAudioPlayer, respecting system sound settings
// Volume: 0.3 (30% of system volume)
// Preload on app launch for zero-latency playback
```

### Sound Creation

Options for creating the sounds:
1. **AI generation** — Tools like Suno, Stable Audio, or ElevenLabs sound effects
2. **Sample libraries** — Freesound.org has singing bowl and chime recordings under CC0
3. **Manual recording** — Record actual singing bowl strikes, process in Audacity
4. **Commission** — Hire a sound designer on Fiverr for $50-100

Recommendation: Start with AI-generated or sample library sounds. Replace with custom recordings later if the generated ones aren't perfect.

---

## Screen-by-Screen Redesign

### 1. Transcribe (Main Screen) — The Hero

**Current**: Dashed-border drop zone + format list + "or" divider + YouTube field + recent list.

**New**:

```
┌──────────────────────────────────────────────────┐
│                                                  │
│     ◇  (80pt merkaba, warm coral, slow spin)     │
│                                                  │
│         Drop a file to transcribe                │
│            or Browse Files                       │
│                                                  │
│   ┌──────────────────────────────────────────┐   │
│   │   ← Large warm card (Surface Elevated)   │   │
│   │   Portal glow on file hover              │   │
│   │   20pt corner radius                     │   │
│   └──────────────────────────────────────────┘   │
│                                                  │
│   ┌──────────────────────────────────────────┐   │
│   │  ▶  Paste a YouTube link                 │   │
│   │  [______________________________]  [→]   │   │
│   └──────────────────────────────────────────┘   │
│                                                  │
│  Recent ─────────────────────────────────────    │
│  ◎ "George Hotz Programming..."  YouTube  Done   │
│  ◎ "Interview with..."           21 MB    Done   │
│  ◎ "Product meeting notes"       3 min    Done   │
└──────────────────────────────────────────────────┘

◎ = sonic mandala thumbnail (32pt, monochrome)
```

**Changes from current**:
- No dashed border → solid warm card
- No format list → implied by drop affordance
- No "or" divider → visual separation between cards
- Merkaba is hero element, not a small icon
- "Browse Files" is inline text link, not a separate button
- Recent list rows use sonic mandala thumbnails instead of colored icon squares
- Never show UUID filenames — always derive a human-readable name

### 2. Dictation History — The Timeline

**Current**: Flat list, tiny timestamps, text beside time column.

**New**: Card-based, text-first, with sonic mandala identity.

```
┌──────────────────────────────────────────────────┐
│  🔍 Search dictations...                         │
│                                                  │
│  TODAY                                           │
│  ┌──────────────────────────────────────────┐    │
│  │  ◎  "And be honest."                     │    │
│  │     7:32 AM · 1 sec            📋  ···   │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │  ◎  "Also likely that they supervised    │    │
│  │     fine-tuned on a lot of traces..."    │    │
│  │     12:57 AM · 26 sec    ▶  📋  ···     │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  YESTERDAY                                       │
│  ┌──────────────────────────────────────────┐    │
│  │  ◎  "Testing, testing, carrying it."     │    │
│  │     11:38 PM · 1 sec            📋  ···  │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  ┌─── Now Playing ──────────────────────────┐    │
│  │  ▶  "Testing testing..."  ═══▓──── 0:07  │    │
│  └──────────────────────────────────────────┘    │
└──────────────────────────────────────────────────┘

◎ = sonic mandala thumbnail (32pt, monochrome)
```

**Changes from current**:
- Card per dictation (warm background, rounded corners)
- Sonic mandala replaces the blank leading space
- Transcript text is the star — larger, primary
- Metadata (time, duration) below the text, not beside it
- Actions (play, copy, more) always visible at bottom-right of card — not hidden behind hover
- Hover still highlights the card, but buttons don't disappear
- Section headers ("TODAY") in accent color, not tertiary
- Generous spacing between cards

### 3. Vocabulary — The Guide

**Current**: Dense Form, segmented picker, numbered pipeline steps, separate tips section.

**New**: Visual, card-based, human language.

```
┌──────────────────────────────────────────────────┐
│                                                  │
│  How should your text sound?                     │
│                                                  │
│  ┌────────────┐    ┌────────────┐                │
│  │   ✏️ Raw    │    │  ✨ Clean   │               │
│  │  As spoken  │    │  Polished  │               │
│  └────────────┘    └────────────┘                │
│                                                  │
│  The Clean Pipeline                              │
│  ┌──────────────────────────────────────────┐    │
│  │                                          │    │
│  │  1. Remove fillers                       │    │
│  │     um, uh, like, you know               │    │
│  │                                          │    │
│  │  2. Fix words                   Manage → │    │
│  │     3 custom corrections                 │    │
│  │                                          │    │
│  │  3. Expand snippets             Manage → │    │
│  │     2 text snippets                      │    │
│  │                                          │    │
│  │  4. Clean whitespace                     │    │
│  │     Fixes spacing & punctuation          │    │
│  │                                          │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  Changes take effect on your next dictation.     │
└──────────────────────────────────────────────────┘
```

**Changes from current**:
- "How should your text sound?" → human question, not "Processing Mode"
- Two big selectable cards instead of segmented picker
- Pipeline as one visual card with inline "Manage" links
- No separate Tips section — one line of context at bottom
- Larger text, warmer colors, more whitespace

### 4. Settings

Still form-based (it's settings, don't over-design), but warmer:

- License section: warm banner when unlocked ("You're all set!"), friendly trial countdown card
- Custom toggle style with coral accent
- Warmer section headers
- Version footer: merkaba in accent color

### 5. Transcription Result View

- Sonic mandala as hero element (120pt, full color, above transcript)
- Warmer timestamp styling
- SacredGeometryDivider stays (it's elegant)
- Export bar with warmer button styling

### 6. Empty States

Every empty state is a **personality moment**:

| Empty State | Copy | Visual |
|-------------|------|--------|
| No dictations | "Your voice, captured. Press Fn to start." | Large warm merkaba, gentle pulse |
| No transcriptions | "Drop a file and watch the magic happen." | Merkaba with subtle upward particle drift |
| Search no results | "Nothing matched. Try different words?" | Merkaba at low opacity, still |
| Error | "Hmm, something went wrong." + actionable detail | Warm error card, not stark red |

### 7. Onboarding

Same flow, warmer personality:
- **Welcome**: Large merkaba (120pt) with particle effects, hero moment
- **Permission steps**: Larger icons, warmer explanations
- **Done**: Celebration — merkaba pulses with golden bloom

---

## Animation & Micro-interactions

### Transitions

- **Content swaps**: Fade + slight scale (0.97 → 1.0), not just opacity
- **Sidebar selection**: Smooth background color slide
- **Cards appearing**: Staggered fade-in from bottom (50ms delay each)

### Delight Moments

| Trigger | Animation | Sound |
|---------|-----------|-------|
| File dropped into portal | Particles converge, merkaba brightens, card lifts | `file_dropped.aif` |
| Transcription complete | Golden bloom from merkaba, mandala generated | `transcription_complete.aif` |
| Copy to clipboard | Brief green flash on button | `copy_click.aif` (optional) |
| Recording start | (Pill handles this — unchanged) | `record_start.aif` |
| Recording stop | (Pill handles this — unchanged) | `record_stop.aif` |
| Error | Card fades in with warm red tint | `error_soft.aif` |

### Loading

- Transcription progress: Merkaba spinner with circular progress ring in accent color
- Download progress: Animated bar inside a warm card

---

## Implementation Scope

### Files Changed

| File | Change | Lines (est.) |
|------|--------|-------------|
| `DesignSystem.swift` | **Rewrite** | ~150 (was 72) |
| `SacredGeometry.swift` | **Major update** | ~350 (was 228) |
| `TranscribeView.swift` | **Rewrite** | ~350 (was 446) |
| `DictationHistoryView.swift` | **Major update** | ~400 (was 350) |
| `VocabularyView.swift` | **Rewrite** | ~150 (was 123) |
| `SettingsView.swift` | **Moderate** | ~230 (was 215) |
| `OnboardingFlowView.swift` | **Major update** | ~550 (was 522) |
| `TranscriptResultView.swift` | **Moderate** | ~280 (was 252) |
| `MainWindowView.swift` | **Minor** | ~70 (was 65) |
| New: `SonicMandalaView.swift` | **New** | ~200 |
| New: `ParticleSystem.swift` | **New** | ~150 |
| New: `SoundManager.swift` | **New** | ~80 |
| New: `PortalDropZone.swift` | **New** | ~200 |
| Sound assets (6 files) | **New** | N/A |

### What Does NOT Change

- `DictationOverlayView.swift` — Zero changes
- `DictationOverlayController.swift` — Zero changes
- `IdlePillView.swift` — Zero changes
- `IdlePillController.swift` — Zero changes
- `WaveformView.swift` — Zero changes (only used in pill)
- All ViewModels — This is view-layer only
- `MacParakeetCore/` — Zero changes
- All tests — Still pass (they test logic, not UI)

### New Files

1. **`SonicMandalaView.swift`** — Circular waveform visualization from audio data
2. **`ParticleSystem.swift`** — Lightweight particle effects for merkaba hero contexts
3. **`SoundManager.swift`** — Audio feedback system with preloaded sounds
4. **`PortalDropZone.swift`** — The new drop zone with portal effect (extract from TranscribeView for clarity)
5. **Sound assets** — 6 `.aif` files in app bundle

---

## Migration Phases

### Phase 1: Foundation
- Rewrite `DesignSystem.swift` — new colors, typography, spacing, layout tokens
- Light/dark theme support via `@Environment(\.colorScheme)`
- All views auto-update (token names stay same, values change)

### Phase 2: Sonic Mandala + Particle System
- Build `SonicMandalaView` — generation algorithm, 32pt and 120pt renderers
- Build `ParticleSystem` — lightweight, accessibility-respecting
- Test mandala quality at small sizes with real audio data

### Phase 3: Transcribe Screen (Hero)
- Portal drop zone with particle effects
- Merkaba as state-reactive hero element
- YouTube URL card redesign
- Recent list with mandala thumbnails
- Sound integration for file drop + transcription complete

### Phase 4: Dictation History
- Card-based rows with mandala thumbnails
- Always-visible actions
- Warmer section headers and empty state

### Phase 5: Vocabulary + Settings + Onboarding
- Visual toggle for processing mode
- Card-based pipeline
- Warmer settings
- Onboarding hero moments

### Phase 6: Sound Design + Polish
- Create/source all 6 sound assets
- Integrate SoundManager
- Recording start/stop sounds (coordinate with pill — sounds play, pill doesn't change)
- Final polish pass on all screens

### Phase 7: Light Theme Default
- Switch default to light
- Verify all screens in both themes
- Ensure dark theme still looks premium

---

## Success Criteria

1. A **non-technical person** opens the app and immediately knows what to do
2. The **drop zone** feels inviting — you WANT to drop a file there
3. **Empty states** make you smile, not feel confused
4. The **merkaba** feels magical, not mathematical
5. The **sonic mandala** is beautiful at 32pt — each one unique, recognizable
6. The **sounds** feel crafted, not generic — people notice and appreciate them
7. The app has **personality** — it doesn't look like every other macOS utility
8. It still feels **premium** — warm ≠ cheap, friendly ≠ childish
9. **Both themes work** — light as default, dark as strong alternative
10. **All 360 tests still pass** — this is a view-layer change only

---

## Anti-patterns to Avoid

- **Gratuitous animation** — Every animation serves a purpose. No animation for animation's sake.
- **Childish** — "UI for 5-year-olds" means SIMPLE, not cartoonish. Things 3 is simple enough for anyone but looks premium.
- **Over-rounded** — Use appropriate radii per context. Not 20pt on everything.
- **Too colorful** — Accent is for actions/highlights. 90% of UI is neutral. One accent, used with discipline.
- **Noisy mandalas** — If the sonic mandala looks like a blob at 32pt, it's wrong. Quality > complexity.
- **Loud sounds** — If someone turns off sounds after one day, they were too loud or too frequent.
- **Touching the pill** — The dictation overlay and idle pill are perfect. Resist the urge.
