# MacParakeet · Brand Asset Library

> Status: **ACTIVE**
>
> Raw ingredients for promotional and editorial design — vector marks, palette,
> composition templates, and ready-to-grab raster exports.

## Philosophy

The MacParakeet mark is a single-stroke calligraphic parakeet rooted in
**calligraphic warmth and Daoist simplicity** (see `docs/brand-identity.md`).
The whole bird reads as one continuous gesture, like signing your name.

This asset library extends that voice into editorial and Pop contexts without
betraying it. Two principles govern every artifact in here:

1. **Quiet by default, loud only when chosen.** The brand resting state is
   coral on cream with the line mark — calm, confident, minimal. The Pop
   palette and silhouette mark are reserved for **moments**: launches,
   anniversaries, social campaigns, posters. Don't dress the chrome in pop.
2. **Pop with discipline.** Andy Warhol's color is loud, but Warhol's
   *composition* is rigorous — flat color fields, repeated form, rhythm. Our
   pop tributes are equally disciplined: curated palette, tight grids, no
   gradients/shadows/glows, two layers max (figure + ground).

## What's in here

```
brand-assets/
├── README.md                       you are here
├── marks/                          the bird, as vector source
│   └── parakeet-line.svg           the canonical brand mark — used everywhere
├── palette/                        the colors
│   ├── palette.json                machine-readable hex + role + guidance
│   ├── palette.css                 CSS variables for web
│   ├── palette.svg                 designer swatch sheet (vector)
│   └── palette.png                 designer swatch sheet (raster)
├── compositions/                   reusable layouts (edit, don't ship as-is)
│   ├── single-portrait.svg         atomic 1:1 portrait — ground + figure
│   ├── warhol-3x4.svg              twelve-tile Pop tribute, 3 cols × 4 rows
│   ├── wordmark-lockup.svg         16:9 horizontal lockup with tagline
│   ├── og-image.svg                1200×630 social meta card
│   ├── social-square.svg           1080×1080 Instagram / general feed
│   └── social-story.svg            1080×1920 IG Story / TikTok / Reels cover
├── exports/                        ready-to-grab PNG renders
│   ├── parakeet-line-{ink,paper,coral}-{256,512,1024,2048,4096}.png
│   ├── single-portrait.png
│   ├── warhol-3x4.png
│   ├── wordmark-lockup.png
│   ├── og-image.png
│   ├── social-square.png
│   └── social-story.png
└── scripts/
    └── render.sh                   regenerate every PNG from SVG sources
```

## The mark

There's one canonical mark: `marks/parakeet-line.svg`. It's a calligraphic
single-stroke parakeet — head, beak, eye dot, body curve, looped tail — traced
from `Assets/AppIcon-1024x1024.png`. It carries the brand voice (calm,
confident, minimal) at every size: legible at 18 pt, beautiful at 4096 px,
strong enough to tile in a Warhol grid and delicate enough for chrome.

The mark uses `fill="currentColor"`. Recolor by setting CSS `color`, by
swapping `currentColor` for a hex literal, or via `<use color="…">` — pick the
mechanism your tool understands.

Why one mark and not two: an earlier draft of this library had a second
"silhouette" sibling for Pop work. It killed the calligraphic detail — the
looped tail flattened into a blob — and that's the opposite of the brand voice.
The line mark already tiles powerfully on flat color fields; it doesn't need a
heftier sibling.

## The palette

Twelve colors. Coral leads. Ink and paper anchor.

![palette](palette/palette.png)

See `palette/palette.json` for hex codes, RGB values, role notes, and pairing
guidance. The file is the source of truth — `palette.css` and `palette.svg`
are derived presentations of the same data.

**Coral (#E86B3B)** mirrors `DesignSystem.Colors.accent` in-app. Every other
palette color is chosen to read cleanly against ink, against paper, and beside
coral. **Aqua** is coral's complement and the strongest Pop partner.

Use the palette for:
- Posters and tile compositions (any color may be ground or figure)
- Social campaigns where you want energy without abandoning the brand
- Editorial work — blog headers, conference badges, event-specific assets

Do **not** use the palette for:
- App chrome (the in-app accent is coral; everything else is system color)
- Marketing chrome that's brand-anchored (use ink/paper/coral)
- Text body color or rules — coral and ink only

## Compositions

Each `compositions/*.svg` is a **template**, not a finished asset. The expected
workflow:

1. Open the SVG in your tool of choice (Figma, Affinity, Inkscape, raw editor).
2. Edit the `<rect fill="…">` to swap the ground.
3. Edit `<use color="…">` to swap the figure.
4. Add type, decoration, photography on top as the campaign demands.
5. Export to PNG/PDF/JPG at the size you need.

The `<symbol id="bird">` block defines the mark once per file. Reusing it via
`<use href="#bird" color="…">` keeps recolors cheap and consistent.

### When in doubt

| You need…                              | Start from…                                |
| -------------------------------------- | ------------------------------------------ |
| Hero image for the website             | `wordmark-lockup.svg`                      |
| GitHub social preview / Twitter card   | `og-image.svg`                             |
| Instagram feed post                    | `social-square.svg`                        |
| Instagram Story / TikTok cover         | `social-story.svg`                         |
| Conference poster, t-shirt, sticker    | `warhol-3x4.svg` (or `single-portrait.svg`) |
| Blog header, slide background          | `single-portrait.svg`                      |

Every composition inlines the canonical line mark as a `<symbol id="bird">`.
The shape is the same everywhere; what changes per composition is the layout,
type, ground color, and figure color.

## Recoloring recipes

### CSS / web (inline SVG)

The cleanest path: paste the contents of `marks/parakeet-line.svg` directly into your HTML, then drive `currentColor` from CSS.

```html
<link rel="stylesheet" href="brand-assets/palette/palette.css"/>
<style>
  .brand-tile {
    background: var(--mp-coral);
    color: var(--mp-paper);          /* the bird inherits this */
    width: 200px; aspect-ratio: 1;
  }
</style>

<div class="brand-tile">
  <!-- inline the contents of marks/parakeet-line.svg here -->
  <svg viewBox="0 0 1024 1024" width="100%" height="100%">…</svg>
</div>
```

### Search-and-replace (any composition SVG)

Each composition follows the same shape:
- The `<rect …>` near the top of the file sets the **ground** color via its `fill` attribute.
- Each `<use href="#bird" … color="…">` sets the **figure** color via its `color` attribute (which `currentColor` on the symbol's paths inherits).

Swap those two attributes to recompose. No other surgery needed.

### Programmatic batch (rsvg / ImageMagick)

```bash
# Render the line mark in aqua at 2048px on a paper background:
sed 's|currentColor|#3FC5C2|g' brand-assets/marks/parakeet-line.svg \
  | rsvg-convert -w 2048 -h 2048 -b "#F8F4EC" -o aqua-on-paper.png
```

## Regenerating exports

After editing any source SVG:

```bash
brand-assets/scripts/render.sh
```

Regenerates every PNG in `exports/` and the palette swatch sheet from current
SVG sources. Requires `librsvg` (`brew install librsvg`).

## Provenance

The line mark (`parakeet-line.svg`) was traced from the canonical 1024×1024
PNG (`Assets/AppIcon-1024x1024.png`) using `potrace` after a luminance
threshold isolated the bird, then re-coordinated into a clean 0..1024
viewBox. Four paths: compound body with eye-hole (fill-rule evenodd), iris dot,
beak, and the small cheek/tail-curve flourish.

The SVG is independent of `Sources/MacParakeet/Resources/parakeet-mark.png` —
that PNG remains the runtime asset path and source of truth for the shipping
app. The vector source lives here for design work that PNG can't do (infinite
scaling, recoloring, vector-native composition).

## Don'ts (these match `docs/brand-identity.md`)

- No gradients, drop shadows, glows, or "glassmorphism" on the mark.
- No outlines or strokes added on top of the mark — it's already calligraphic.
- No rotation or flipping of the mark — gaze direction is intentional.
- No simplifying the silhouette (e.g. dropping the looped tail). The detail is the brand.
- No new brand colors introduced ad-hoc — work from the palette.
- No mark below 16 px (illegible). Prefer 18 px and up.

## Adding to this library

When you add a new asset:
1. Author the **SVG source** first — never start from raster.
2. Use `currentColor` on the bird so it stays recolorable.
3. Reference colors from the palette — no one-off hexes.
4. Wire it into `scripts/render.sh` so the PNG export regenerates with the rest.
5. Document the intent in this README — *what* it's for, *when* to use it.

---

*The library is the workshop, not the gallery. Compose freely; ship with discipline.*
