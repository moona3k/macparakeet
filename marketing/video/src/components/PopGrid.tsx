import React from 'react';
import {
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { ParakeetMark } from './ParakeetMark';
import { palette } from '../theme/tokens';

/**
 * The 12 contrast-validated Warhol pairs from
 * `brand-assets/palette/palette.json` § "tile-pairs". Each pair has been
 * eyeballed for ≥3:1 luminance contrast between ground and figure, so
 * any row composed from this list reads at any size.
 */
export const TILE_PAIRS: ReadonlyArray<{ ground: string; figure: string }> = [
  { ground: palette.coral, figure: palette.ink },        // 0
  { ground: palette.aqua, figure: palette.ink },         // 1
  { ground: palette.marigold, figure: palette.ink },     // 2
  { ground: palette.magenta, figure: palette.paper },    // 3
  { ground: palette.cobalt, figure: palette.paper },     // 4
  { ground: palette.forest, figure: palette.lemon },     // 5
  { ground: palette.lemon, figure: palette.ink },        // 6
  { ground: palette.lavender, figure: palette.ink },     // 7
  { ground: palette.brick, figure: palette.paper },      // 8
  { ground: palette.ink, figure: palette.marigold },     // 9
  { ground: palette.lime, figure: palette.cobalt },      // 10
  { ground: palette.paper, figure: palette.ink },        // 11
];

/**
 * The curated "brand Pop" subset — the 6 highest-impact contrast pairs.
 * Used by BrandShow30 by default. palette.json guidance: "A 12-tile grid
 * using 4 colors arranged in a rhythm reads more 'considered' than 12
 * unique tiles. Pop with discipline."
 */
export const POP_BRAND_PAIRS: ReadonlyArray<number> = [0, 4, 2, 3, 5, 7];
// coral+ink, cobalt+paper, marigold+ink, magenta+paper, forest+lemon, lavender+ink

interface PopGridProps {
  /** Number of visible rows. Direction alternates: row 0 →, row 1 ←, etc. */
  rows?: number;
  /** Tiles visible in a single row at any moment. */
  tilesPerRowVisible?: number;
  /**
   * Per-row marquee speeds in px/s. If shorter than `rows`, indices cycle.
   * Asymmetric speeds read as "weaving"; uniform speeds read as treadmill.
   */
  rowSpeeds?: ReadonlyArray<number>;
  /**
   * Pre-rendered offset per row in tile-widths (0..1). Premium move:
   * stagger the rows so the grid is already misaligned on frame 0
   * rather than starting from a static aligned state.
   */
  rowInitialOffsets?: ReadonlyArray<number>;
  /**
   * Indices into TILE_PAIRS to use. Defaults to the curated brand subset.
   * Pass [0..11] for the full 12-pair palette.
   */
  pairIndices?: ReadonlyArray<number>;
  /**
   * Starting position within `pairIndices` per row. Designed so no two
   * vertically adjacent tiles share a ground color.
   */
  rowSeeds?: ReadonlyArray<number>;
  /** Frames between each row's fade-in. 0 = no stagger. */
  entranceStaggerFrames?: number;
  /** Total frames the entrance reveal occupies (after stagger offset). */
  entranceDurationFrames?: number;
}

/**
 * Andy Warhol meets a kinetic typography poster.
 *
 * Full-bleed grid of parakeets in the brand's Pop palette. Rows scroll
 * in opposite directions at *asymmetric* speeds with pre-offset start
 * positions, so the grid feels like a weaving loom rather than a
 * synchronized treadmill. Rows reveal in a staggered cascade.
 *
 * Tile colors are validated for ≥3:1 contrast — every parakeet reads at
 * any zoom against any ground. Default subset is the 6 highest-impact
 * brand pairs; pass `pairIndices` for the full 12-color set.
 */
export const PopGrid: React.FC<PopGridProps> = ({
  rows = 4,
  tilesPerRowVisible = 6,
  rowSpeeds = [130, 95, 165, 115],
  rowInitialOffsets = [0, 0.5, 0.25, 0.75],
  pairIndices = POP_BRAND_PAIRS,
  rowSeeds = [0, 3, 1, 4],
  entranceStaggerFrames = 6,
  entranceDurationFrames = 18,
}) => {
  const frame = useCurrentFrame();
  const { fps, width: canvasWidth, height: canvasHeight } = useVideoConfig();

  const tileWidth = canvasWidth / tilesPerRowVisible;
  const tileHeight = canvasHeight / rows;
  const cycleWidth = tileWidth * tilesPerRowVisible;
  const tilesPerStrip = tilesPerRowVisible * 2; // first half == second half for seamless loop

  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      }}
    >
      {Array.from({ length: rows }).map((_, rowIdx) => {
        const direction = rowIdx % 2 === 0 ? 1 : -1;
        const speed = rowSpeeds[rowIdx % rowSpeeds.length];
        const initialOffsetPx =
          (rowInitialOffsets[rowIdx % rowInitialOffsets.length] ?? 0) * tileWidth;
        const t = (frame / fps) * speed + initialOffsetPx;
        const offset = ((t % cycleWidth) + cycleWidth) % cycleWidth;
        // direction = +1 → tiles appear to slide right (translateX from -cycle → 0)
        // direction = -1 → tiles appear to slide left  (translateX from 0 → -cycle)
        const tx = direction === 1 ? -cycleWidth + offset : -offset;
        const seed = rowSeeds[rowIdx % rowSeeds.length];

        // Staggered entrance: row 0 fades in first, then row 1, etc.
        const rowStart = rowIdx * entranceStaggerFrames;
        const rowOpacity = interpolate(
          frame,
          [rowStart, rowStart + entranceDurationFrames],
          [0, 1],
          { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' },
        );

        return (
          <div
            key={rowIdx}
            style={{
              height: tileHeight,
              position: 'relative',
              overflow: 'hidden',
              opacity: rowOpacity,
            }}
          >
            <div
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                height: '100%',
                display: 'flex',
                transform: `translateX(${tx}px)`,
                willChange: 'transform',
              }}
            >
              {Array.from({ length: tilesPerStrip }).map((_, tileIdx) => {
                // Repeat first half in second half for seamless loop.
                const idxInCycle = tileIdx % tilesPerRowVisible;
                const pairIdx =
                  pairIndices[(seed + idxInCycle) % pairIndices.length];
                const pair = TILE_PAIRS[pairIdx];
                return (
                  <Tile
                    key={tileIdx}
                    width={tileWidth}
                    height={tileHeight}
                    ground={pair.ground}
                    figure={pair.figure}
                  />
                );
              })}
            </div>
          </div>
        );
      })}
    </div>
  );
};

interface TileProps {
  width: number;
  height: number;
  ground: string;
  figure: string;
}

const Tile: React.FC<TileProps> = ({ width, height, ground, figure }) => {
  const markSize = Math.min(width, height) * 0.62;
  return (
    <div
      style={{
        width,
        height,
        flexShrink: 0,
        backgroundColor: ground,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <ParakeetMark size={markSize} color={figure} />
    </div>
  );
};
