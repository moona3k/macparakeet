# MacParakeet Brand Identity

> Status: **ACTIVE**

## Logo: Stylized Parakeet

A single-stroke illustration of a parakeet in profile — rounded head with a
small beak, an eye dot, a body curve descending into a graceful looped tail.

### Philosophy

The mark is rooted in calligraphic warmth and Daoist simplicity: the whole
bird reads as one continuous gesture, like signing your name.

- **The head + beak** is a soft circular crown with a small angular beak —
  alert, attentive, listening
- **The eye dot** is the moment of attention — alive, watching, aware
- **The body curve** flows down from the head into the tail, suggesting
  motion at rest
- **The looped tail** echoes the head's roundness — two circles in
  conversation, the bird's posture mid-perch
- **Handwritten feel** — warm, personal, not corporate

### Design Principles

1. **One continuous stroke** — the bird is a single drawn line; no fills
   except the eye dot
2. **Scalable** — reads clearly from 18px menu bar to 1024px app icon
3. **Template-ready** — single-color (white, or accent) mark adapts
   to any background via macOS template rendering
4. **Timeless** — no trendy gradients, no 3D effects, no sharp corners
   beyond the beak

## Canonical Asset

The brand mark ships as a high-resolution white-on-near-black PNG. The PNG
remains the runtime source of truth; the vector source lives in
`brand-assets/marks/` for design work that raster can't do (infinite scaling,
recoloring, poster-scale composition).

| File | Size | Use |
|------|------|-----|
| `Assets/AppIcon-1024x1024.png` | 1024×1024 | Runtime source of truth for the parakeet illustration; reference asset for design work |
| `Sources/MacParakeet/Resources/parakeet-mark.png` | 1024×1024 | Same PNG copied into the SwiftPM runtime bundle so app code can load it via `Bundle.module` |
| `Sources/MacParakeet/Resources/menubar-icon.png` / `@2x.png` | 18pt / 36px | Hand-tuned smaller variant for the macOS menu bar; not derived from the 1024px source — separate authored asset |
| `brand-assets/marks/parakeet-line.svg` | vector | Vector trace of the canonical mark — used everywhere from chrome to Pop tiles. Recolorable via `currentColor`. See `brand-assets/README.md`. |

### Sizing & Legibility

| Context | Size | Notes |
|---------|------|-------|
| Menu bar | 18 px | Authored as a dedicated asset; tested target |
| Inline (assistant avatars, status chips) | 18 pt | Bumped to 18 from 16 because head/eye/tail blur together below ~16 px |
| Dock / About | 1024 px | Full canonical illustration |

16 px is the practical legibility floor: the eye dot becomes a sub-pixel
speck and the looped tail loses definition. Prefer 18 px and up.

### Color Variants

| Variant | Use Case | Path |
|---------|----------|------|
| White on near-black | Dock icon, menu bar (template-tinted by macOS) | App icon, menu bar default |
| Accent (warm coral-orange) | Inline UI surfaces — assistant avatars in the live Ask tab, future brand-anchored chrome | `BreathWaveLogo` view + `DesignSystem.Colors.accent` |
| Custom tint | Any color via SwiftUI `.foregroundStyle()` on a template-rendered `Image` | `BreathWaveIcon.brandMark` |

### Implementation

The mark is consumed at runtime through three paths:

- **Inline SwiftUI** — `BreathWaveLogo(size:tint:opacity:)` wraps
  `BreathWaveIcon.brandMark(pointSize:)` in an `Image` with
  `.renderingMode(.template)`. Backed by the 1024×1024 parakeet PNG,
  converted at first access from white-on-near-black to alpha-only via a
  Rec. 709 luminance → alpha pass (one-shot, process-cached). SwiftUI then
  downscales to the requested point size with `.interpolation(.high)`.
- **Menu bar** — `BreathWaveIcon.menuBarIcon(pointSize:state:)` loads the
  hand-tuned 18 pt PNG, sets `isTemplate = true`, and lets macOS adapt it
  to light/dark menu bars. Recording / processing states overlay a colored
  status dot.
- **App icon (dock / Finder)** — the 1024×1024 PNG is bundled via
  `Assets/AppIcon.icns`; macOS handles all sizing.

> **Note:** `BreathWaveIcon.appIcon(size:)` is a programmatic Core Graphics
> drawing of an *earlier* "cursive P" mark and is not used by any shipping
> code path. It is retained only as historical reference; do not rely on it
> for new surfaces. New inline brand surfaces should go through
> `BreathWaveIcon.brandMark` so they share the canonical parakeet asset.

### Usage Guidelines

**Do:**
- Use the template (single-color) version for UI elements; let
  `.foregroundStyle()` carry the tint
- Let macOS handle light/dark adaptation in the menu bar via
  `isTemplate = true`
- Scale proportionally — never stretch or skew
- Maintain clear space equal to the eye-dot diameter around the mark

**Don't:**
- Add outlines, shadows, glows, or color effects beyond a single tint
- Use the mark below 16 px (illegible)
- Rotate or flip the mark (the bird's posture and gaze direction are
  intentional)
- Place on busy backgrounds without sufficient contrast
- Render the mark from code geometry — always go through the canonical PNG
  asset and the shared loader, otherwise the mark drifts from what ships

### App Icon (Dock / App Store)

The app icon is the parakeet illustration on a near-black background with
macOS-standard rounded corners.

```text
Background: near-black with a subtle radial vignette toward the center
Mark: White (#FFFFFF), single-stroke parakeet illustration
Corner radius: macOS standard (~22% of icon size)
```

## Typography

MacParakeet uses the system font stack:

| Context | Font |
|---------|------|
| App UI | SF Pro (system default) |
| Menu bar | SF Pro |
| Website | Inter / system-ui |
| Marketing | SF Pro Display (headlines) |

## Color Palette

MacParakeet uses minimal, purposeful color:

| Token | Value | Use |
|-------|-------|-----|
| Accent | `DesignSystem.Colors.accent` (warm coral-orange) | Interactive elements, active states, inline brand mark |
| Success | `DesignSystem.Colors.successGreen` | Copy confirmation, completion |
| Warning | `DesignSystem.Colors.warningAmber` | Cautions, "catching up" indicators |
| Error | `DesignSystem.Colors.errorRed` | Destructive actions |
| Background | System window background | App chrome |

The app intentionally uses system colors for chrome to feel native. The
accent coral-orange is reserved for moments of attention — it is the same
color the brand mark wears when it appears inline.

For **promotional and editorial work** (posters, social campaigns, launch
art, anniversary tributes), an extended Pop palette anchored on the same
coral lives in `brand-assets/palette/`. Twelve curated colors, each chosen
to read against ink and paper and to sit beside coral. The Pop palette is
**only** for moments — it must not leak into chrome. See
`brand-assets/README.md` for guidance.

## Brand Voice

| Attribute | Description |
|-----------|-------------|
| **Tone** | Calm, confident, minimal |
| **Language** | Simple, direct, no jargon |
| **Personality** | Quiet competence — does the work, doesn't brag |
| **Tagline** | "The fastest, most private voice app for Mac." |

---

*The parakeet mark is the canonical brand identity for MacParakeet.*
