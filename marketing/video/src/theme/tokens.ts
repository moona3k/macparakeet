/**
 * MacParakeet design tokens for video rendering.
 *
 * Authoritative source: brand-assets/palette/palette.json + docs/brand-identity.md.
 * Keep this file in sync when those change.
 */

export const palette = {
  // Anchors
  ink: '#0E0F12',
  paper: '#F8F4EC',

  // Brand accent (mirrors DesignSystem.Colors.accent in-app)
  coral: '#E86B3B',

  // Pop family — use sparingly, one tile per composition
  marigold: '#F4B83A',
  lemon: '#F1E04E',
  lime: '#A6D74E',
  forest: '#2F7A4F',
  aqua: '#3FC5C2',
  cobalt: '#2A52BE',
  lavender: '#A684E8',
  magenta: '#E03B92',
  brick: '#B53D2C',
} as const;

export const typography = {
  // Stack: SF Pro Display where available (macOS preview), Inter for headless render.
  display:
    '"SF Pro Display", "Inter", -apple-system, BlinkMacSystemFont, system-ui, sans-serif',
  body: '"SF Pro Text", "Inter", -apple-system, BlinkMacSystemFont, system-ui, sans-serif',

  // Display sizes in px @ 1920×1080
  hookPrimary: 132,
  hookSecondary: 88,
  closingHeadline: 64,
  caption: 36,
  lowerThird: 28,
} as const;

export const motion = {
  // Spring presets tuned for natural-feeling text entrances at 60fps.
  springSoft: { damping: 18, stiffness: 80, mass: 0.6 },
  springFirm: { damping: 14, stiffness: 120, mass: 0.5 },

  // Frame counts at 60fps
  beatHold: 48, // 0.8s — minimum hold between phrases
  wordStagger: 9, // 0.15s — stagger between revealed words
  phraseStagger: 24, // 0.4s — stagger between phrase entrances
  fadeIn: 18, // 0.3s — short fade
} as const;
