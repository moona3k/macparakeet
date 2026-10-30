import { readFileSync, readdirSync, copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const output = resolve(process.argv[2] ?? '');
if (!process.argv[2]) throw new Error('Usage: node scripts/notices.js DESTINATION');
const meta = JSON.parse(readFileSync(join(root, 'dist/ask-helper.meta.json'), 'utf8'));
const dependencies = new Set();
for (const input of Object.keys(meta.inputs)) {
  const marker = input.lastIndexOf('node_modules/');
  if (marker < 0) continue;
  const segments = input.slice(marker + 'node_modules/'.length).split('/');
  dependencies.add(segments[0].startsWith('@') ? segments.slice(0, 2).join('/') : segments[0]);
}
const manifest = [];
for (const name of [...dependencies].sort()) {
  const packageDir = join(root, 'node_modules', name);
  const info = JSON.parse(readFileSync(join(packageDir, 'package.json'), 'utf8'));
  const target = join(output, 'Dependencies', name);
  mkdirSync(target, { recursive: true });
  const licenses = readdirSync(packageDir).filter((filename) => /^(LICENSE|LICENCE|NOTICE|COPYING)([._-].*)?$/i.test(filename));
  if (licenses.length === 0 && name.startsWith('@earendil-works/')) {
    copyFileSync(join(root, 'legal/Pi-MIT-LICENSE'), join(target, 'LICENSE'));
    licenses.push('LICENSE');
  } else if (licenses.length === 0) {
    throw new Error(`Bundled dependency ${name} has no license file`);
  } else {
    for (const filename of licenses) copyFileSync(join(packageDir, filename), join(target, filename));
  }
  manifest.push({ name, version: info.version, license: info.license, files: licenses });
}
mkdirSync(output, { recursive: true });
writeFileSync(join(output, 'dependencies.json'), JSON.stringify({ generatedFrom: 'esbuild metafile', packages: manifest }, null, 2) + '\n');
