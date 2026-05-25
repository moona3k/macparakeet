import React from 'react';
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { AppIcon } from './AppIcon';
import { motion, palette, typography } from '../theme/tokens';
import { SCRIPT } from '../content/script';

interface OfficialLogoProps {
  /** Show the URL line under the logo. Defaults to true. */
  withWordmark?: boolean;
}

/**
 * The dramatic black/white logo finale.
 *
 * Ink (#0E0F12) full-bleed ground; the canonical app icon scales in
 * large and dominant; the URL appears in coral after a hold. The
 * AppIcon's own near-black background blends with the ink canvas so
 * only the calligraphic white parakeet reads — that's the "official
 * logo" moment.
 *
 * Designed to follow a Pop-palette section (PopGrid) so the silence
 * and dark ground feel earned, not abrupt.
 */
export const OfficialLogo: React.FC<OfficialLogoProps> = ({
  withWordmark = true,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Icon enters with a firm spring scale + opacity ramp.
  const iconProgress = spring({
    frame,
    fps,
    config: motion.springFirm,
    durationInFrames: 48,
  });
  const iconScale = interpolate(iconProgress, [0, 1], [0.7, 1]);
  const iconOpacity = interpolate(frame, [0, 24], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  // Subtle breath after the entrance settles.
  const breath = Math.sin((frame / fps) * 2 * Math.PI * 0.25) * 0.012 + 1;

  // Wordmark fades in after the icon has settled.
  const wordmarkOpacity = interpolate(frame, [72, 108], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const wordmarkTranslate = interpolate(frame, [72, 108], [16, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill style={{ backgroundColor: palette.ink }}>
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 72,
        }}
      >
        <div
          style={{
            opacity: iconOpacity,
            transform: `scale(${iconScale * breath})`,
            willChange: 'transform, opacity',
          }}
        >
          {/* Large icon; the icon's own near-black bg blends with the */}
          {/* ink ground so only the white calligraphic parakeet reads. */}
          <AppIcon size={720} rounded={false} />
        </div>

        {withWordmark ? (
          <div
            style={{
              fontFamily: typography.display,
              fontSize: 56,
              fontWeight: 700,
              color: palette.coral,
              letterSpacing: -1,
              opacity: wordmarkOpacity,
              transform: `translateY(${wordmarkTranslate}px)`,
              willChange: 'transform, opacity',
            }}
          >
            {SCRIPT.closing.wordmark}
          </div>
        ) : null}
      </div>
    </AbsoluteFill>
  );
};
