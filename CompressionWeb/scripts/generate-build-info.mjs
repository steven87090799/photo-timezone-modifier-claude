#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createBuildInfo, readReleaseAuthority } from './build-metadata-lib.mjs';
import { validateBuildInfo } from '../build-identity.mjs';

const root = process.env.NEXPRESS_ROOT
  ? path.resolve(process.env.NEXPRESS_ROOT)
  : path.join(import.meta.dirname, '..');
const release = await readReleaseAuthority(root);

const workerPath = path.join(root, 'worker.js');
const workerBeforeReleaseSync = await readFile(workerPath, 'utf8');
const workerReleaseSynced = workerBeforeReleaseSync.replace(
  /(runtime-policy\.js\?v=)[^&"']+/,
  `$1${release.releaseGeneration}`,
);
await writeFile(workerPath, workerReleaseSynced, 'utf8');

const buildInfo = await createBuildInfo(root);
if (buildInfo.channel !== 'development' && buildInfo.revision === 'unavailable') {
  throw new Error(`${buildInfo.channel} build metadata requires a Git revision`);
}
const validation = validateBuildInfo(buildInfo);
if (!validation.ok) throw new Error(`generated build metadata is invalid: ${validation.errors.join(', ')}`);

const workerSource = await readFile(workerPath, 'utf8');
if (!/runtime-policy\.js\?v=[^&"']+&b=[^&"']+/.test(workerSource)) {
  throw new Error('worker.js generated runtime-policy identity marker was not found');
}
const worker = workerSource.replace(
  /(runtime-policy\.js\?v=[^&"']+&b=)[^&"']+/,
  `$1${encodeURIComponent(buildInfo.buildId)}`,
);
await writeFile(workerPath, worker, 'utf8');

await writeFile(path.join(root, 'build-info.json'), `${JSON.stringify(buildInfo, null, 2)}\n`, 'utf8');
console.log(`Generated ${buildInfo.buildId} (${buildInfo.assetCount} runtime assets).`);
