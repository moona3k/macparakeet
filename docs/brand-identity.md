# MacParakeet Brand Identity

> Status: **ACTIVE**

## Logo: Cursive P

An enclosed circular bowl with a centered dot and a cursive loop tail — P for Parakeet.

### Philosophy

The Cursive P is rooted in Daoist simplicity and calligraphic warmth.

- **The enclosed bowl** is a complete circle — wholeness, a bird's head in profile
- **The dot** is the bird's eye — alive, watching, aware
- **The cursive loop tail** echoes the bowl's circular rhythm — two circles in harmony
- **Handwritten feel** — warm, personal, not corporate. Like signing your name.

### Design Principles

1. **Ultra-minimal** — Three elements only (circle, dot, tail)
2. **Scalable** — Reads clearly from 18px menu bar to 512px app icon
3. **Template-ready** — Monochrome design adapts to any background via macOS template rendering
4. **Timeless** — No trendy gradients, no 3D effects, no sharp corners

### Canonical Geometry

The logo is defined on a 128x128 viewBox:

```
Viewbox: 0 0 128 128

Bowl: circle cx=68, cy=34, r=26
Dot:  circle cx=68, cy=34, r=6

Stem + cursive loop tail:
  M 42,34 L 42,82
  C 42,100 30,110 18,112
  C 6,114 2,106 8,98
  C 14,90 30,88 42,92
  Stroke: round cap, width 7 (standard) / 10 (small sizes)
```

At small sizes (menu bar, favicons), stroke width and dot radius are increased for legibility:

| Context | Stroke Width | Dot Radius |
|---------|-------------|-----------|
| Standard (48px+) | 7 | 6 |
| Small (18-32px) | 9-10 | 7-8 |
| Menu bar (18px) | 10 | 8 |

### Color Variants

| Variant | Use Case | File |
|---------|----------|------|
| `currentColor` | Adaptive (inherits context color) | `breath-wave-logo.svg` |
| White on transparent | Dark backgrounds, menu bar | `breath-wave-logo-white.svg` |
| Dark on transparent | Light backgrounds, print | `breath-wave-logo-dark.svg` |

### Implementation

The menu bar icon is generated programmatically in `Sources/MacParakeet/BreathWaveIcon.swift` using Core Graphics:

- `BreathWaveIcon.menuBarIcon(pointSize:)` — Template image for menu bar (auto-adapts to light/dark)
- `BreathWaveIcon.appIcon(size:)` — Full color icon for dock/App Store

No asset catalogs or external image files are needed at runtime. SVG files in `Assets/` are for documentation and website use.

### Usage Guidelines

**Do:**
- Use the template (monochrome) version for UI elements
- Let macOS handle light/dark adaptation via `isTemplate = true`
- Scale proportionally — never stretch or skew
- Maintain clear space equal to the dot radius around the logo

**Don't:**
- Add outlines, shadows, or effects to the logo
- Use the logo at sizes below 16px (illegible)
- Rotate or flip the logo (the wave direction is intentional)
- Place on busy backgrounds without sufficient contrast

### App Icon (Dock / App Store)

The app icon uses the Breath Wave in white on a deep teal-blue gradient background with macOS-standard rounded corners.

```
Background gradient:
  Top:    rgb(31, 51, 82)   — #1F3352
  Bottom: rgb(20, 36, 61)   — #14243D

Logo: White (#FFFFFF)
Corner radius: ~22% of icon size (macOS standard)
Padding: ~15.6% of icon size on each side
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
| Accent | System accent (blue default) | Interactive elements, active states |
| Success | `DesignSystem.Colors.successGreen` | Copy confirmation, completion |
| Warning | `DesignSystem.Colors.warningOrange` | Errors, cautions |
| Background | System window background | App chrome |

The app intentionally uses system colors to feel native. No custom brand color is imposed on the UI — the Breath Wave logo is the brand identity, not a color.

## Brand Voice

| Attribute | Description |
|-----------|-------------|
| **Tone** | Calm, confident, minimal |
| **Language** | Simple, direct, no jargon |
| **Personality** | Quiet competence — does the work, doesn't brag |
| **Tagline** | "The fastest, most private voice app for Mac." |

---

*The Breath Wave logo was designed for MacParakeet in February 2026.*
