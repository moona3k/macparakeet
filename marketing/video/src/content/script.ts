/**
 * The locked MacParakeet marketing script — single source of truth for every
 * composition in this project.
 *
 * Human-readable spec: docs/marketing.md
 * This file is the machine-readable mirror. Keep them in sync; the spec is
 * authoritative when they disagree.
 *
 * Changing one string here updates every rendered video on the next
 * `npm run render:*`.
 */

export const SCRIPT = {
  hook: {
    primary: 'Dictate. Transcribe. Record meetings.',
    supporting: 'One Mac app.',
  },
  closing: {
    headline: 'Free. Open source. Built for Apple Silicon.',
    wordmark: 'macparakeet.com',
  },
  modes: {
    dictation: {
      title: 'Dictate anywhere',
      caption: 'Apple Silicon · 155× realtime · runs offline',
      durationSec: 16,
      vo: 'MacParakeet dictates anywhere on your Mac. Tap a hotkey, speak, the text appears. Apple Silicon. 155 times realtime. Runs offline.',
      screencast: 'screencasts/dictation.mp4',
    },
    transcription: {
      title: 'Drop in audio, video, or a YouTube link',
      caption: 'Audio · Video · YouTube · Export anywhere',
      durationSec: 16,
      vo: 'Drop in any audio, any video, even a YouTube link. Get a transcript with timestamps and speakers. Export it any way you need.',
      screencast: 'screencasts/transcription.mp4',
    },
    meeting: {
      title: 'Record meetings, live notes, local transcription',
      caption: 'System audio + mic · Live notes · Local transcription',
      durationSec: 16,
      vo: "And during a meeting, MacParakeet records both sides — system audio plus your mic — gives you a live notepad, and when you're done, hands you the transcript and the summary.",
      screencast: 'screencasts/meeting.mp4',
    },
  },
  bridges: {
    openingLine: 'Three things people use voice for on a Mac. Most apps do one.',
    closingLine: 'Free. Open source. Built for Apple Silicon. MacParakeet.',
  },
} as const;

export type Script = typeof SCRIPT;
