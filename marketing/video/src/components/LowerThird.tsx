import React from 'react';
import {
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { motion, palette, typography } from '../theme/tokens';

interface LowerThirdProps {
  text: string;
  /** Frame at which the lower-third enters. Defaults to 6 (0.1s @ 60fps). */
  startFrame?: number;
}

/**
 * Reusable caption strip at the bottom-left of the frame.
 *
 * Coral accent bar, ink type on a translucent paper backdrop. Slides up
 * with a soft spring on entrance. Designed to read against busy
 * screencast footage without obscuring the content.
 */
export const LowerThird: React.FC<LowerThirdProps> = ({
  text,
  startFrame = 6,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const local = frame - startFrame;

  const progress = spring({
    frame: local,
    fps,
    config: motion.springSoft,
    durationInFrames: 30,
  });
  const opacity = interpolate(local, [0, 10], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const translateY = interpolate(progress, [0, 1], [24, 0]);

  return (
    <div
      style={{
        position: 'absolute',
        bottom: 64,
        left: 64,
        display: 'flex',
        alignItems: 'center',
        gap: 20,
        padding: '18px 28px',
        backgroundColor: `${palette.paper}F0`,
        backdropFilter: 'blur(8px)',
        borderRadius: 12,
        opacity,
        transform: `translateY(${translateY}px)`,
        willChange: 'transform, opacity',
      }}
    >
      <div
        style={{
          width: 4,
          height: 36,
          backgroundColor: palette.coral,
          borderRadius: 2,
        }}
      />
      <div
        style={{
          fontFamily: typography.body,
          fontSize: typography.lowerThird,
          fontWeight: 500,
          color: palette.ink,
          letterSpacing: -0.2,
          whiteSpace: 'nowrap',
        }}
      >
        {text}
      </div>
    </div>
  );
};
