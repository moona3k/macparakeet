import React from 'react';
import {
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { motion, palette, typography } from '../theme/tokens';

interface HookRevealProps {
  /** "Dictate. Transcribe. Record meetings." */
  primary: string;
  /** "One Mac app." */
  supporting: string;
  /** Frame offset before the reveal begins. */
  startFrame?: number;
}

/**
 * Staircase reveal for the locked hook.
 *
 * Splits the primary string on sentence boundaries and animates each
 * phrase in with a stagger, then reveals the supporting line in coral
 * after a short hold. Tuned for 60fps; uses spring physics so the motion
 * feels organic rather than scripted.
 */
export const HookReveal: React.FC<HookRevealProps> = ({
  primary,
  supporting,
  startFrame = 0,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const phrases = primary
    .split(/(?<=\.)\s+/)
    .filter((p) => p.trim().length > 0);

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 56,
      }}
    >
      <div
        style={{
          display: 'flex',
          flexWrap: 'wrap',
          rowGap: 0,
          columnGap: 30,
          justifyContent: 'center',
          maxWidth: 1600,
          fontFamily: typography.display,
          fontSize: typography.hookPrimary,
          fontWeight: 700,
          color: palette.ink,
          letterSpacing: -2,
          lineHeight: 1.05,
        }}
      >
        {phrases.map((phrase, i) => {
          const phraseStart = startFrame + i * motion.phraseStagger;
          const local = frame - phraseStart;

          const progress = spring({
            frame: local,
            fps,
            config: motion.springFirm,
            durationInFrames: 32,
          });
          const opacity = interpolate(local, [0, 10], [0, 1], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          });
          const translateY = interpolate(progress, [0, 1], [28, 0]);

          return (
            <span
              key={i}
              style={{
                display: 'inline-block',
                opacity,
                transform: `translateY(${translateY}px)`,
                willChange: 'transform, opacity',
              }}
            >
              {phrase}
            </span>
          );
        })}
      </div>

      <SupportingLine
        text={supporting}
        startFrame={
          startFrame + phrases.length * motion.phraseStagger + motion.fadeIn
        }
      />
    </div>
  );
};

interface SupportingLineProps {
  text: string;
  startFrame: number;
}

const SupportingLine: React.FC<SupportingLineProps> = ({
  text,
  startFrame,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const local = frame - startFrame;

  const progress = spring({
    frame: local,
    fps,
    config: motion.springSoft,
    durationInFrames: 40,
  });
  const opacity = interpolate(local, [0, 12], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const translateY = interpolate(progress, [0, 1], [18, 0]);

  return (
    <div
      style={{
        fontFamily: typography.display,
        fontSize: typography.hookSecondary,
        fontWeight: 600,
        color: palette.coral,
        letterSpacing: -1,
        opacity,
        transform: `translateY(${translateY}px)`,
        willChange: 'transform, opacity',
      }}
    >
      {text}
    </div>
  );
};
