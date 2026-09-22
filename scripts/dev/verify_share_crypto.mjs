// Browser-compatible Web Crypto acceptance gate for the canonical Swift fixture.
// No dependencies, network access, or real user data.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { webcrypto } from 'node:crypto';

const fixture = JSON.parse(await readFile(new URL('../../spec/contracts/fixtures/share-crypto-v1.json', import.meta.url), 'utf8'));
const bytes = value => Buffer.from(value, 'base64url');
const aad = (locator, revision) => new TextEncoder().encode(`com.macparakeet.share-envelope\0v1\0${locator}\0${revision}`);
assert.equal(new TextDecoder().decode(aad(fixture.locator, fixture.contentRevision)), fixture.aad);
async function decrypt(keyValue, locator, revision, ciphertext) {
  const key = await webcrypto.subtle.importKey('raw', bytes(keyValue), 'AES-GCM', false, ['decrypt']);
  return webcrypto.subtle.decrypt({
    name: 'AES-GCM', iv: bytes(fixture.envelope.nonce),
    additionalData: aad(locator, revision), tagLength: 128,
  }, key, bytes(ciphertext));
}
const { contentKey, locator, contentRevision, envelope, negative } = fixture;
const opened = await decrypt(contentKey, locator, contentRevision, envelope.ciphertext);
assert.equal(new TextDecoder('utf-8', { fatal: true }).decode(opened), fixture.plaintext);
assert.equal(JSON.parse(fixture.plaintext).schema, 'com.macparakeet.share-bundle');
for (const args of [
  [negative.wrongContentKey, locator, contentRevision, envelope.ciphertext],
  [contentKey, negative.wrongLocator, contentRevision, envelope.ciphertext],
  [contentKey, locator, negative.wrongContentRevision, envelope.ciphertext],
  [contentKey, locator, contentRevision, negative.mutatedCiphertext],
  [contentKey, locator, contentRevision, negative.truncatedCiphertext],
]) await assert.rejects(decrypt(...args));
console.log('Share fixture: Web Crypto round trip and all five authentication negatives passed.');
