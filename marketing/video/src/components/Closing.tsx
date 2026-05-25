import React from 'react';
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { motion, palette, typography } from '../theme/tokens';
import { AppIcon } from './AppIcon';
import { SCRIPT } from '../content/script';

/**
 * Closing card — used by Demo60 and HeroLoop30 as the final beat.
 *
 * Paper-cream background, the actual MacParakeet app icon (white
 * parakeet on near-black, rounded macOS corners, soft shadow), ink
 * headline, coral URL. The icon's near-black background creates a
 * dock-like card sitting on the warm cream ground — reads as "this is
 * the app you're installing" rather than abstract branding.
 */
export const Closing: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const iconProgress = spring({
    frame: frame - 4,
    fps,
    config: motion.springSoft,
    durationInFrames: 40,
  });
  const iconOpacity = interpolate(frame, [0, 28], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const iconScale = interpolate(iconProgress, [0, 1], [0.92, 1]);

  const headlineProgress = spring({
    frame: frame - 24,
    fps,
    config: motion.springSoft,
    durationInFrames: 36,
  });
  const headlineOpacity = interpolate(frame, [24, 42], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const headlineTranslate = interpolate(headlineProgress, [0, 1], [16, 0]);

  const urlProgress = spring({
    frame: frame - 46,
    fps,
    config: motion.springSoft,
    durationInFrames: 36,
  });
  const urlOpacity = interpolate(frame, [46, 64], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const urlTranslate = interpolate(urlProgress, [0, 1], [12, 0]);

  // Subtle breath on the icon — ±1% scale over a slow cycle.
  const breath = Math.sin((frame / fps) * 2 * Math.PI * 0.3) * 0.01 + 1;

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
          gap: 56,
        }}
      >
        <div
          style={{
            opacity: iconOpacity,
            transform: `scale(${iconScale * breath})`,
            willChange: 'transform, opacity',
          }}
        >
          <AppIcon size={220} shadow />
        </div>

        <div
          style={{
            fontFamily: typography.display,
            fontSize: typography.closingHeadline,
            fontWeight: 600,
            color: palette.ink,
            letterSpacing: -1,
            textAlign: 'center',
            opacity: headlineOpacity,
            transform: `translateY(${headlineTranslate}px)`,
            willChange: 'transform, opacity',
          }}
        >
          {SCRIPT.closing.headline}
        </div>

        <div
          style={{
            fontFamily: typography.display,
            fontSize: 56,
            fontWeight: 700,
            color: palette.coral,
            letterSpacing: -1,
            opacity: urlOpacity,
            transform: `translateY(${urlTranslate}px)`,
            willChange: 'transform, opacity',
          }}
        >
          {SCRIPT.closing.wordmark}
        </div>
      </div>
    </AbsoluteFill>
  );
};
