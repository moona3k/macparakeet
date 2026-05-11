#!/usr/bin/env tsx
/**
 * Audition Kokoro voices for the MacParakeet brand voice.
 *
 * Generates a short test phrase in each of a curated shortlist of voices,
 * writes them to `public/audio/audition/`, and prints which file is which
 * so you can listen and pick.
 *
 * Usage:
 *   npm run audition
 *
 * Then play each .wav in the output dir and decide. Lock your choice in
 * `.env` via:
 *   KOKORO_VOICE=af_bella
 *
 * The shortlist is curated for the brand voice direction: calm, confident,
 * minimal, slight warmth. If none of these feel right, see the full voice
 * catalog in scripts/generate-voice.ts.
 */

import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { KokoroTTS } from 'kokoro-js';
import { SCRIPT } from '../src/content/script.js';

// Mirror of kokoro-js's internal voice union. Not exported by the
// package, so re-declared here for type safety.
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
const DTYPE = (process.env.KOKORO_DTYPE ?? 'q8') as 'fp32' | 'fp16' | 'q8' | 'q4' | 'q4f16';
const OUT_DIR = path.resolve(__dirname, '../public/audio/audition');

// Curated shortlist — voices that lean calm/professional/warm.
// Mixes male/female, American/British so you can pick the best fit.
const SHORTLIST: Array<{ id: KokoroVoice; note: string }> = [
  { id: 'af_bella', note: 'American Female · warm · default recommendation' },
  { id: 'af_heart', note: 'American Female · soft · the "literary narrator" voice' },
  { id: 'af_sarah', note: 'American Female · calm · clear diction' },
  { id: 'af_nicole', note: 'American Female · measured · slightly lower register' },
  { id: 'am_michael', note: 'American Male · clear · professional' },
  { id: 'am_onyx', note: 'American Male · resonant · deeper register' },
  { id: 'bm_george', note: 'British Male · understated · "BBC narrator"' },
  { id: 'bf_emma', note: 'British Female · precise · documentary feel' },
];

// Test phrase: the locked hook + supporting line + a mode VO so you hear
// both display copy and prose. ~10 seconds of audio.
const TEST_PHRASE = [
  SCRIPT.hook.primary,
  SCRIPT.hook.supporting,
  SCRIPT.modes.dictation.vo,
].join(' ');

async function main(): Promise<void> {
  console.log(`Loading Kokoro-82M (${DTYPE})…`);
  const tts = await KokoroTTS.from_pretrained(MODEL_ID, { dtype: DTYPE });
  console.log('Model ready. Auditioning shortlist:\n');

  await fs.mkdir(OUT_DIR, { recursive: true });

  for (const { id, note } of SHORTLIST) {
    const start = Date.now();
    const audio = await tts.generate(TEST_PHRASE, { voice: id });
    const outPath = path.join(OUT_DIR, `audition-${id}.wav`);
    await audio.save(outPath);
    const elapsed = ((Date.now() - start) / 1000).toFixed(1);
    console.log(`✓ ${id.padEnd(14)} ${note.padEnd(58)} (${elapsed}s)`);
  }

  console.log(`\nDone. Listen to the files in ${path.relative(process.cwd(), OUT_DIR)}/.`);
  console.log('Lock your pick in .env:  KOKORO_VOICE=<id>');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
