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
 * Pop Brand Film — 15s portrait (1080×1920).
 *
 * Vertical sibling of BrandShow30 for Instagram Reels, TikTok, X mobile.
 * 5 rows × 4 visible tiles — taller individual tiles fit portrait
 * orientation, more rows give the grid more weight in the frame. Beats
 * are compressed proportionally:
 *
 *   0:00 – 0:01   Quiet intro
 *   0:01 – 0:10   Pop grid in motion
 *   0:10 – 0:12   Fade to ink
 *   0:12 – 0:15   Official logo + URL
 */
interface BrandShow15PortraitProps {
  audioReady?: boolean;
}

export const BrandShow15Portrait: React.FC<BrandShow15PortraitProps> = ({
  audioReady = false,
}) => {
  const { fps } = useVideoConfig();

  const INTRO_END = fps * 1;
  const GRID_START = fps * 1;
  const GRID_END = fps * 10;
  const FADE_START = fps * 10;
  const FADE_END = fps * 12;
  const LOGO_START = fps * 12;
  const TOTAL = fps * 15;

  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      {audioReady ? (
        <>
          <Audio
            src={staticFile('audio/music/brand-track-15s.wav')}
            volume={0.85}
          />
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
    frame: frame - 3,
    fps,
    config: motion.springFirm,
    durationInFrames: 30,
  });
  const opacity = interpolate(frame, [0, 18], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const scale = interpolate(progress, [0, 1], [0.9, 1]);
  const breath = Math.sin((frame / fps) * 2 * Math.PI * 0.6) * 0.015 + 1;

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
        <ParakeetMark size={260} color={palette.coral} />
      </div>
    </AbsoluteFill>
  );
};

const PopGridSection: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      {/* 5 rows × 4 visible tiles — portrait-tuned variant of the grid. */}
      <PopGrid
        rows={5}
        tilesPerRowVisible={4}
        rowSpeeds={[150, 110, 180, 130, 100]}
        rowInitialOffsets={[0, 0.4, 0.2, 0.6, 0.8]}
        rowSeeds={[0, 3, 1, 4, 2]}
        entranceStaggerFrames={4}
        entranceDurationFrames={14}
      />
    </AbsoluteFill>
  );
};

const FadeToInk: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const total = fps * 2;
  const t = frame / total;
  const eased = t * t;
  const opacity = Math.min(Math.max(eased, 0), 1);

  return <AbsoluteFill style={{ backgroundColor: palette.ink, opacity }} />;
};
