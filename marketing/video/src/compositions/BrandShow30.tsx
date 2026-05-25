import React from 'react';
import {
  AbsoluteFill,
  Audio,
  interpolate,
  Sequence,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { OfficialLogo } from '../components/OfficialLogo';
import { ParakeetMark } from '../components/ParakeetMark';
import { PopGrid } from '../components/PopGrid';
import { motion, palette } from '../theme/tokens';

/**
 * Pop Brand Film — 30s.
 *
 * Pure visual identity, no explainer copy. For launch moments, social
 * campaigns, anniversary loops. The "Warhol moment" the Pop palette
 * exists for (see palette.json § brand-fidelity).
 *
 * Beat structure:
 *   0:00 – 0:02   Quiet intro:  single coral parakeet on paper-cream
 *   0:02 – 0:20   POP GRID:     4 rows × 6 visible tiles, asymmetric speeds
 *                               and pre-offset starts → weaving motion
 *   0:20 – 0:23   Fade to ink:  the grid dissolves to near-black
 *   0:23 – 0:30   Official logo: white parakeet on ink + URL in coral
 *
 * Audio slots are optional — drop tracks into `public/audio/music/`:
 *   - `brand-track.wav` : 30s music bed (ducks to silence under logo)
 *   - `logo-sting.wav`  : single chime at the logo-reveal beat
 * Both are gracefully no-op if the files don't exist (the slots are
 * gated by props passed from Root.tsx).
 */
interface BrandShow30Props {
  /** Pass `true` once music + sting exist in public/audio/music/. */
  audioReady?: boolean;
}

export const BrandShow30: React.FC<BrandShow30Props> = ({
  audioReady = false,
}) => {
  const { fps } = useVideoConfig();

  const INTRO_END = fps * 2;
  const GRID_START = fps * 2;
  const GRID_END = fps * 20;
  const FADE_START = fps * 20;
  const FADE_END = fps * 23;
  const LOGO_START = fps * 23;
  const TOTAL = fps * 30;

  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      {audioReady ? (
        <>
          <Audio src={staticFile('audio/music/brand-track.wav')} volume={0.85} />
          {/* Logo sting fires at the moment the grid clears. */}
          <Sequence from={LOGO_START} durationInFrames={TOTAL - LOGO_START}>
            <Audio
              src={staticFile('audio/music/logo-sting.wav')}
              volume={1}
            />
          </Sequence>
        </>
      ) : null}

      <Sequence from={0} durationInFrames={INTRO_END} name="Intro">
        <QuietIntro />
      </Sequence>

      <Sequence
        from={GRID_START}
        durationInFrames={GRID_END - GRID_START}
        name="Pop Grid"
      >
        <PopGridSection />
      </Sequence>

      <Sequence
        from={FADE_START}
        durationInFrames={FADE_END - FADE_START}
        name="Fade to ink"
      >
        <FadeToInk />
      </Sequence>

      <Sequence
        from={LOGO_START}
        durationInFrames={TOTAL - LOGO_START}
        name="Official logo"
      >
        <OfficialLogo />
      </Sequence>
    </AbsoluteFill>
  );
};

const QuietIntro: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const progress = spring({
    frame: frame - 6,
    fps,
    config: motion.springSoft,
    durationInFrames: 40,
  });
  const opacity = interpolate(frame, [0, 24], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const scale = interpolate(progress, [0, 1], [0.92, 1]);
  const breath = Math.sin((frame / fps) * 2 * Math.PI * 0.5) * 0.015 + 1;

  return (
    <AbsoluteFill
      style={{
        backgroundColor: palette.paper,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        style={{
          opacity,
          transform: `scale(${scale * breath})`,
          willChange: 'transform, opacity',
        }}
      >
        <ParakeetMark size={200} color={palette.coral} />
      </div>
    </AbsoluteFill>
  );
};

const PopGridSection: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      <PopGrid
        rows={4}
        tilesPerRowVisible={6}
        rowSpeeds={[130, 95, 165, 115]}
        rowInitialOffsets={[0, 0.5, 0.25, 0.75]}
        rowSeeds={[0, 3, 1, 4]}
      />
    </AbsoluteFill>
  );
};

/**
 * Ink curtain that fades up over the grid. Uses a quadratic ease so the
 * start of the fade is slow and the back half accelerates — feels more
 * decisive than a linear ramp.
 */
const FadeToInk: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const total = fps * 3;
  const t = frame / total;
  const eased = t * t; // ease-in (quadratic)
  const opacity = Math.min(Math.max(eased, 0), 1);

  return (
    <AbsoluteFill style={{ backgroundColor: palette.ink, opacity }} />
  );
};
