import React from 'react';
import { AbsoluteFill, OffthreadVideo, staticFile } from 'remotion';
import { palette, typography } from '../theme/tokens';

interface ScreencastSlotProps {
  /** Filename inside `public/screencasts/`, e.g. "dictation.mp4". */
  src: string;
  /** Human-readable label for the placeholder when the file isn't there yet. */
  label: string;
  /** Short description shown under the label. */
  hint?: string;
  /**
   * Once you've dropped the actual screencast into `public/screencasts/`,
   * flip this to `true` to play it instead of the placeholder.
   */
  ready?: boolean;
}

/**
 * Slot for a screencast clip captured from MacParakeet.
 *
 * Renders a branded placeholder by default. When you've recorded the
 * actual screencast (via Screen Studio) and dropped it into
 * `public/screencasts/`, pass `ready` and the slot upgrades to the
 * real <OffthreadVideo>.
 *
 * Two-state design (placeholder vs ready) is deliberate: Remotion's
 * media components throw at playback time on missing files — they
 * cannot be caught by React error boundaries — so the safest pattern
 * is to gate them explicitly rather than try/catch.
 */
export const ScreencastSlot: React.FC<ScreencastSlotProps> = ({
  src,
  label,
  hint,
  ready = false,
}) => {
  if (!ready) {
    return <Placeholder label={label} hint={hint} />;
  }

  // OffthreadVideo is preferred for renders — runs in a worker thread,
  // doesn't block the main compositor. Drops back to <Video> in studio
  // preview automatically.
  return <OffthreadVideo src={staticFile(`screencasts/${src}`)} />;
};

const Placeholder: React.FC<{ label: string; hint?: string }> = ({
  label,
  hint,
}) => {
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
          border: `4px dashed ${palette.ink}33`,
          borderRadius: 24,
          padding: '64px 96px',
          textAlign: 'center',
          maxWidth: 1200,
        }}
      >
        <div
          style={{
            fontFamily: typography.body,
            fontSize: 24,
            fontWeight: 700,
            letterSpacing: 4,
            textTransform: 'uppercase',
            color: palette.coral,
            marginBottom: 16,
          }}
        >
          Screencast Slot
        </div>
        <div
          style={{
            fontFamily: typography.display,
            fontSize: typography.closingHeadline,
            fontWeight: 700,
            color: palette.ink,
            letterSpacing: -1,
            marginBottom: hint ? 24 : 0,
          }}
        >
          {label}
        </div>
        {hint ? (
          <div
            style={{
              fontFamily: typography.body,
              fontSize: 28,
              color: palette.ink,
              opacity: 0.6,
              maxWidth: 800,
              margin: '0 auto',
              lineHeight: 1.4,
            }}
          >
            {hint}
          </div>
        ) : null}
      </div>
    </AbsoluteFill>
  );
};
