#!/usr/bin/env tsx
/**
 * Dump SCRIPT (TypeScript) to JSON for the Python Higgs Audio pipeline.
 *
 * Python can't import a .ts module directly, so we mirror SCRIPT into
 * `src/content/script.json` whenever needed. The Higgs script
 * (`generate-voice-hq.py`) calls this automatically when the JSON is
 * older than the dumper itself.
 *
 * Manual invocation:
 *   npx tsx scripts/dump-script.ts
 */

import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SCRIPT } from '../src/content/script.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const OUT = path.resolve(__dirname, '../src/content/script.json');

async function main(): Promise<void> {
  await fs.writeFile(OUT, JSON.stringify(SCRIPT, null, 2) + '\n');
  console.log(`✓ SCRIPT → ${path.relative(process.cwd(), OUT)}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
