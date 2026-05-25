import React from 'react';
import { AbsoluteFill, Sequence, useVideoConfig } from 'remotion';
import { Closing } from '../components/Closing';
import { LowerThird } from '../components/LowerThird';
import { ScreencastSlot } from '../components/ScreencastSlot';
import { SCRIPT } from '../content/script';
import { palette } from '../theme/tokens';
import { Hook } from './Hook';

/**
 * 30-second autoplay-muted hero loop.
 *
 * Same five beats as Demo60, compressed to 6s each, NO voiceover. On-screen
 * captions carry the message. Designed for:
 *   - macparakeet.com hero (autoplay-muted)
 *   - GitHub README inline embed
 *   - X / Threads autoplay timelines
 *
 * Loops cleanly: the closing card fades back to the cold open visually
 * (both end on paper-cream backgrounds).
 */
export const HeroLoop30: React.FC = () => {
  const { fps } = useVideoConfig();
  const BEAT = fps * 6;

  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      <Sequence from={0} durationInFrames={BEAT} name="Cold open">
        <ScreencastSlot
          src="cold-open.mp4"
          label="Cold Open"
          hint="Hands → Fn tap → text streaming into Slack."
        />
      </Sequence>

      <Sequence from={BEAT} durationInFrames={BEAT} name="Hook">
        <Hook />
      </Sequence>

      <Sequence from={BEAT * 2} durationInFrames={BEAT} name="Dictation">
        <ScreencastSlot
          src={SCRIPT.modes.dictation.screencast.replace('screencasts/', '')}
          label={SCRIPT.modes.dictation.title}
        />
        <LowerThird text={SCRIPT.modes.dictation.caption} startFrame={18} />
      </Sequence>

      <Sequence from={BEAT * 3} durationInFrames={BEAT} name="Transcription">
        <ScreencastSlot
          src={SCRIPT.modes.transcription.screencast.replace('screencasts/', '')}
          label={SCRIPT.modes.transcription.title}
        />
        <LowerThird text={SCRIPT.modes.transcription.caption} startFrame={18} />
      </Sequence>

      <Sequence from={BEAT * 4} durationInFrames={BEAT - fps * 3} name="Meeting">
        <ScreencastSlot
          src={SCRIPT.modes.meeting.screencast.replace('screencasts/', '')}
          label={SCRIPT.modes.meeting.title}
        />
        <LowerThird text={SCRIPT.modes.meeting.caption} startFrame={18} />
      </Sequence>

      <Sequence from={BEAT * 5 - fps * 3} durationInFrames={fps * 3} name="Closing">
        <Closing />
      </Sequence>
    </AbsoluteFill>
  );
};
