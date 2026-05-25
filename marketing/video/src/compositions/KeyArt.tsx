import React from 'react';
import { AbsoluteFill } from 'remotion';
import { ParakeetMark } from '../components/ParakeetMark';
import { TILE_PAIRS } from '../components/PopGrid';
import { palette } from '../theme/tokens';

/**
 * Static key art — the canonical 3×4 Warhol grid.
 *
 * Mirrors `brand-assets/compositions/warhol-3x4.svg` exactly: 12 tiles,
 * 3 columns × 4 rows, every brand-validated pair shown once. No motion,
 * no marquee, no entrance — designed to be rendered as a still PNG via
 * `npm run still:keyart` for use as:
 *
 *   - App Store hero / press kit cover
 *   - GitHub social card / X header
 *   - Launch tweet image (square crop)
 *   - Anniversary post background
 *
 * Aspect ratio is 3:4 portrait (1200×1600 default canvas). Render at 2×
 * for a 2400×3200 press-grade PNG via `--scale=2`.
 */
export const KeyArt: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(3, 1fr)',
          gridTemplateRows: 'repeat(4, 1fr)',
          width: '100%',
          height: '100%',
        }}
      >
        {TILE_PAIRS.map((pair, idx) => (
          <KeyArtTile key={idx} ground={pair.ground} figure={pair.figure} />
        ))}
      </div>
    </AbsoluteFill>
  );
};

interface KeyArtTileProps {
  ground: string;
  figure: string;
}

const KeyArtTile: React.FC<KeyArtTileProps> = ({ ground, figure }) => {
  return (
    <div
      style={{
        backgroundColor: ground,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      {/* Bird sized to ~58% of the tile's shorter dimension — */}
      {/* matches the visual rhythm of brand-assets/compositions/warhol-3x4.svg. */}
      <div style={{ width: '58%', maxWidth: '58%' }}>
        <ParakeetMark size={400} color={figure} />
      </div>
    </div>
  );
};
