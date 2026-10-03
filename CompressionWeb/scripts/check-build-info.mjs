#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { createBuildInfo, expectedBuildId, readReleaseAuthority } from './build-metadata-lib.mjs';
import { validateBuildInfo } from '../build-identity.mjs';

const root = process.env.NEXPRESS_ROOT
  ? path.resolve(process.env.NEXPRESS_ROOT)
  : path.join(import.meta.dirname, '..');
const actual = JSON.parse(await readFile(path.join(root, 'build-info.json'), 'utf8'));
const release = await readReleaseAuthority(root);
const expected = await createBuildInfo(root, {
  builtAt: actual.builtAt,
  revision: actual.revision,
  channel: actual.channel,
});
const errors = [];

const validation = validateBuildInfo(actual);
if (!validation.ok) errors.push(...validation.errors);

for (const field of ['schemaVersion', 'appVersion', 'releaseGeneration', 'channel', 'contentHash', 'assetCount']) {
  if (actual[field] !== expected[field]) errors.push(`${field}: expected ${expected[field]}, got ${actual[field]}`);
}
if (!/^(?:[0-9a-f]{7,40}|unavailable)$/.test(actual.revision || '')) errors.push('revision is malformed');
const builtAtMs = Date.parse(actual.builtAt);
if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(actual.builtAt || '')
    || !Number.isFinite(builtAtMs) || new Date(builtAtMs).toISOString() !== actual.builtAt) {
  errors.push('builtAt is not a canonical UTC ISO-8601 timestamp');
}
const buildId = expectedBuildId(release, actual.revision, expected.contentHash);
if (actual.buildId !== buildId) errors.push(`buildId: expected ${buildId}, got ${actual.buildId}`);

const index = await readFile(path.join(root, 'index.html'), 'utf8');
if (!index.includes(`<meta name="nexpress-build-id" content="${actual.buildId}">`)) errors.push('index.html build ID is stale');
if (!index.includes(`<meta name="nexpress-content-hash" content="${actual.contentHash}">`)) errors.push('index.html content hash is stale');
if (!index.includes(`./main.js?v=${actual.releaseGeneration}&b=${encodeURIComponent(actual.buildId)}`)) errors.push('index.html main module identity is stale');
if (!index.includes(`./vendor/jszip.min.js?v=${actual.releaseGeneration}&b=${encodeURIComponent(actual.buildId)}`)) errors.push('index.html JSZip identity is stale');
const sw = await readFile(path.join(root, 'sw.js'), 'utf8');
if (!sw.includes(`const BUILD_ID = '${actual.buildId}';`)) errors.push('sw.js build ID is stale');
if (!sw.includes(`const CONTENT_HASH = '${actual.contentHash}';`)) errors.push('sw.js content hash is stale');
const worker = await readFile(path.join(root, 'worker.js'), 'utf8');
if (!worker.includes(`runtime-policy.js?v=${actual.releaseGeneration}&b=${encodeURIComponent(actual.buildId)}`)) {
  errors.push('worker.js runtime-policy identity is stale');
}

if (errors.length) {
  console.error('Build metadata is stale or invalid:');
  errors.forEach(error => console.error(`  - ${error}`));
  process.exit(1);
}
console.log(`Build metadata OK: ${actual.buildId} (${actual.assetCount} runtime assets).`);
