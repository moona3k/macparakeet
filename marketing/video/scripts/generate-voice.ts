#!/usr/bin/env tsx
/**
 * Generate voiceover audio via Kokoro-82M, 100% local.
 *
 * Why Kokoro?
 *   - #1 open-weight TTS on the Artificial Analysis leaderboard (ELO 1059)
 *   - 82M params, MIT licensed, runs anywhere
 *   - Pure Node via kokoro-js — no Python, no model-download dance
 *   - Studio-quality on calm/measured delivery, which is the brand voice
 *
 * For dramatic / multi-speaker / emotional renders, see the Higgs Audio V2
 * upgrade path in `generate-voice-hq.py`.
 * For voice cloning from a reference recording, see the F5-TTS roadmap
 * note in marketing/video/README.md.
 *
 * Reads SCRIPT (`src/content/script.ts`) and writes WAV files per scene
 * plus a master demo voiceover into `src/assets/audio/`. Files are
 * gitignored — regenerate on demand whenever the script changes.
 *
 * Usage:
 *   npm run voice                         # generate every scene
 *   npm run voice -- mode-dictation       # only one scene
 *   npm run voice -- master-demo          # only the long-form master VO
 *
 * Voice direction:
 *   Default voice is `af_bella` — warm, calm, professional. Override via
 *   KOKORO_VOICE env var. Brand voice is "calm, confident, minimal,
 *   slight warmth" — see docs/brand-identity.md § Brand Voice.
 *
 * Voice catalog (English presets shipped with Kokoro v1.0):
 *   American Female: af_alloy, af_aoede, af_bella, af_heart, af_jessica,
 *                    af_kore, af_nicole, af_nova, af_river, af_sarah, af_sky
 *   American Male:   am_adam, am_echo, am_eric, am_fenrir, am_liam,
 *                    am_michael, am_onyx, am_puck, am_santa
 *   British Female:  bf_alice, bf_emma, bf_isabella, bf_lily
 *   British Male:    bm_daniel, bm_fable, bm_george, bm_lewis
 */

import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { KokoroTTS } from 'kokoro-js';
import { SCRIPT } from '../src/content/script.js';

// Mirror of kokoro-js's internal voice union (`keyof typeof VOICES`). Not
// exported by the package, so re-declared here for type safety. Keep in
// sync with the catalog in the script header.
type KokoroVoice =
  | 'af_alloy' | 'af_aoede' | 'af_bella' | 'af_heart' | 'af_jessica'
  | 'af_kore' | 'af_nicole' | 'af_nova' | 'af_river' | 'af_sarah' | 'af_sky'
  | 'am_adam' | 'am_echo' | 'am_eric' | 'am_fenrir' | 'am_liam'
  | 'am_michael' | 'am_onyx' | 'am_puck' | 'am_santa'
  | 'bf_alice' | 'bf_emma' | 'bf_isabella' | 'bf_lily'
  | 'bm_daniel' | 'bm_fable' | 'bm_george' | 'bm_lewis';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const MODEL_ID = 'onnx-community/Kokoro-82M-v1.0-ONNX';
// VoiceId is a string-literal union exported by kokoro-js. Env values are
// trusted to match (validated against the catalog in the script header).
const VOICE = (process.env.KOKORO_VOICE ?? 'af_bella') as KokoroVoice;
// q8 = 8-bit quantized: good quality, ~80MB model, fast on CPU.
// Use "fp32" for absolute maximum quality (slower, larger).
const DTYPE = (process.env.KOKORO_DTYPE ?? 'q8') as 'fp32' | 'fp16' | 'q8' | 'q4' | 'q4f16';
const OUT_DIR = path.resolve(__dirname, '../public/audio');

interface VoiceJob {
  name: string;
  text: string;
}

const jobs: VoiceJob[] = [
  { name: 'hook-opener', text: SCRIPT.bridges.openingLine },
  { name: 'mode-dictation', text: SCRIPT.modes.dictation.vo },
  { name: 'mode-transcription', text: SCRIPT.modes.transcription.vo },
  { name: 'mode-meeting', text: SCRIPT.modes.meeting.vo },
  { name: 'closing', text: SCRIPT.bridges.closingLine },
  {
    name: 'master-demo',
    text: [
      SCRIPT.bridges.openingLine,
      SCRIPT.modes.dictation.vo,
      SCRIPT.modes.transcription.vo,
      SCRIPT.modes.meeting.vo,
      SCRIPT.bridges.closingLine,
    ].join(' '),
  },
];

async function main(): Promise<void> {
  const requested = process.argv.slice(2);
  const toRun =
    requested.length > 0
      ? jobs.filter((j) => requested.includes(j.name))
      : jobs;

  if (toRun.length === 0) {
    console.error(
      'No matching jobs. Available:',
      jobs.map((j) => j.name).join(', '),
    );
    process.exit(1);
  }

  console.log(`Loading Kokoro-82M (${DTYPE}, voice=${VOICE})…`);
  const tts = await KokoroTTS.from_pretrained(MODEL_ID, { dtype: DTYPE });
  console.log('Model ready.\n');

  await fs.mkdir(OUT_DIR, { recursive: true });

  for (const job of toRun) {
    const start = Date.now();
    const audio = await tts.generate(job.text, { voice: VOICE });
    const outPath = path.join(OUT_DIR, `${job.name}.wav`);
    await audio.save(outPath);
    const elapsed = ((Date.now() - start) / 1000).toFixed(1);
    console.log(
      `✓ ${job.name.padEnd(20)} → ${path.relative(process.cwd(), outPath)} (${elapsed}s)`,
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
