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

## Canonical Assets

The reusable brand mark and the macOS app icon now have separate source paths.
Use the mark assets for inline UI, editorial work, and recoloring. Use the app
icon assets only for Dock, Finder, Cmd+Tab, About, and installer surfaces where
macOS expects a padded transparent icon shape.

| File | Size | Use |
|------|------|-----|
| `brand-assets/marks/parakeet-line.svg` | vector | Canonical reusable vector mark — used everywhere from chrome to Pop tiles. Recolorable via `currentColor`. See `brand-assets/README.md`. |
| `Sources/MacParakeet/Resources/parakeet-mark.png` | 1024×1024 | Runtime source for inline SwiftUI mark rendering via `Bundle.module`; white-on-near-black so `BreathWaveIcon.brandMark` can convert luminance to alpha. |
| `brand-assets/marks/AppIcon.icon/` | bundle | Icon Composer source for the macOS app icon. Its bundled `Assets/parakeet-line.svg` is a required vendored copy of `brand-assets/marks/parakeet-line.svg`; keep them byte-for-byte in sync. |
| `Assets/AppIcon-1024x1024.png` | 1024×1024 | Transparent padded macOS app-icon source image generated from the app icon source bundle; not the raw reusable mark. |
| `Assets/AppIcon.icns` | multi-size | Shipping macOS icon copied into the app bundle by `scripts/dist/build_app_bundle.sh`. |
| `Sources/MacParakeet/Resources/menubar-icon.png` / `@2x.png` | 18pt / 36px | Hand-tuned smaller variant for the macOS menu bar; not derived from the 1024px source — separate authored asset |

### Sizing & Legibility

| Context | Size | Notes |
|---------|------|-------|
| Menu bar | 18 px | Authored as a dedicated asset; tested target |
| Inline (assistant avatars, status chips) | 18 pt | Bumped to 18 from 16 because head/eye/tail blur together below ~16 px |
| Dock / About | 1024 px source, multi-size `.icns` output | Padded transparent macOS app icon, not the raw reusable mark |

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
  `.renderingMode(.template)`. Backed by
  `Sources/MacParakeet/Resources/parakeet-mark.png`, converted at first access
  from white-on-near-black to alpha-only via a Rec. 709 luminance → alpha pass
  (one-shot, process-cached). SwiftUI then downscales to the requested point
  size with `.interpolation(.high)`.
- **Menu bar** — `BreathWaveIcon.menuBarIcon(pointSize:state:)` loads the
  hand-tuned 18 pt PNG, sets `isTemplate = true`, and lets macOS adapt it
  to light/dark menu bars. Recording / processing states overlay a colored
  status dot.
- **App icon (Dock / Finder / Cmd+Tab)** —
  `brand-assets/marks/AppIcon.icon/` is the Icon Composer source,
  `Assets/AppIcon-1024x1024.png` is the transparent padded 1024 px export, and
  `Assets/AppIcon.icns` is the shipping multi-size icon. The build script copies
  the `.icns` unchanged into the app bundle.

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

The app icon uses the parakeet mark inside a macOS-specific icon container. The
Icon Composer source may carry platform icon metadata such as container shadow,
translucency, and tinted appearance support; those effects belong to the app
icon container, not to the reusable mark assets above.

```text
Background: near-black with a subtle radial vignette toward the center
Mark: White (#FFFFFF), single-stroke parakeet illustration
Shape: transparent padded macOS squircle baked into the 1024 px PNG and .icns
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
| Accent | `DesignSystem.Colors.accent` (warm coral-orange) | Single primary CTA per surface, recording state, AssistantHead, idle/recording pills, sacred geometry, inline brand mark — **not** chrome |
| Neutral chrome | `DesignSystem.Colors.tintNeutral` (system label) | Default `.secondary` button tint, mode pickers, focus rings, most interactive controls |
| Success | `DesignSystem.Colors.successGreen` | Copy confirmation, completion |
| Warning | `DesignSystem.Colors.warningAmber` | Cautions, "catching up" indicators |
| Error | `DesignSystem.Colors.errorRed` | Destructive actions |
| Background | System window background | App chrome |

The app intentionally uses system colors for chrome to feel native. The
accent coral-orange is reserved for moments of attention — it is the same
color the brand mark wears when it appears inline. **Coral on**: one CTA
per surface, recording state, brand surfaces. **Coral off**: secondary
buttons, mode pickers, focus rings, hover, selection. Buttons in the app
express this discipline through the `parakeetAction(_:)` modifier (see
`spec/04-ui-patterns.md` → Buttons).

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
