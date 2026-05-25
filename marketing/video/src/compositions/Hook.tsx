import React from 'react';
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { HookReveal } from '../components/HookReveal';
import { ParakeetMark } from '../components/ParakeetMark';
import { SCRIPT } from '../content/script';
import { motion, palette } from '../theme/tokens';

/**
 * Hook composition — 5 seconds.
 *
 * Validation spike for the Remotion + brand-tokens + script pipeline.
 * Centered coral parakeet mark, paper-cream background, staggered hook
 * reveal, then a supporting line in coral. Everything renders from
 * `SCRIPT.hook` — change the string, get a new video on the next render.
 */
export const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Mark enters: gentle scale + fade between frames 6-46.
  const markProgress = spring({
    frame: frame - 6,
    fps,
    config: motion.springSoft,
    durationInFrames: 40,
  });
  const markOpacity = interpolate(frame, [0, 30], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const markScale = interpolate(markProgress, [0, 1], [0.92, 1]);

  // Subtle breath: ±1.5% scale over the whole 5s hold.
  const breath = Math.sin((frame / fps) * 2 * Math.PI * 0.35) * 0.015 + 1;

  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 64,
          paddingBottom: 32,
        }}
      >
        <div
          style={{
            opacity: markOpacity,
            transform: `scale(${markScale * breath})`,
            willChange: 'transform, opacity',
          }}
        >
          <ParakeetMark size={160} color={palette.coral} />
        </div>

        <HookReveal
          primary={SCRIPT.hook.primary}
          supporting={SCRIPT.hook.supporting}
          startFrame={42}
        />
      </div>
    </AbsoluteFill>
  );
};
