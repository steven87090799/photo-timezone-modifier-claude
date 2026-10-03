#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createBuildInfo, readReleaseAuthority } from './build-metadata-lib.mjs';
import { validateBuildInfo } from '../build-identity.mjs';

const root = process.env.NEXPRESS_ROOT
  ? path.resolve(process.env.NEXPRESS_ROOT)
  : path.join(import.meta.dirname, '..');
const release = await readReleaseAuthority(root);

const indexPath = path.join(root, 'index.html');
const indexBeforeReleaseSync = await readFile(indexPath, 'utf8');
const indexReleaseSynced = indexBeforeReleaseSync
  .replace(/(<meta name="nexpress-release-generation" content=")[^"]*(")/, `$1${release.releaseGeneration}$2`)
  .replace(/(\.\/main\.js\?v=)[^&"']+/, `$1${release.releaseGeneration}`)
  .replace(/(vendor\/jszip\.min\.js\?v=)[^&"']+/, `$1${release.releaseGeneration}`);
await writeFile(indexPath, indexReleaseSynced, 'utf8');

const swPath = path.join(root, 'sw.js');
const swBeforeReleaseSync = await readFile(swPath, 'utf8');
const swReleaseSynced = swBeforeReleaseSync.replace(
  /const CACHE_VERSION = 'v[^']+';/,
  `const CACHE_VERSION = 'v${release.releaseGeneration}';`,
);
await writeFile(swPath, swReleaseSynced, 'utf8');

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

const indexSource = await readFile(indexPath, 'utf8');
if (!/<meta name="nexpress-build-id" content="[^"]*">/.test(indexSource)
    || !/<meta name="nexpress-content-hash" content="[^"]*">/.test(indexSource)
    || !/[?&]b=[^&"']+/.test(indexSource)) {
  throw new Error('index.html generated build identity markers were not found');
}
const index = indexSource
  .replace(/(<meta name="nexpress-build-id" content=")[^"]*(")/, `$1${buildInfo.buildId}$2`)
  .replace(/(<meta name="nexpress-content-hash" content=")[^"]*(")/, `$1${buildInfo.contentHash}$2`)
  .replace(/([?&]b=)[^&"']+/g, `$1${encodeURIComponent(buildInfo.buildId)}`);
await writeFile(indexPath, index, 'utf8');

const swSource = await readFile(swPath, 'utf8');
if (!/const BUILD_ID = '[^']*';/.test(swSource) || !/const CONTENT_HASH = '[^']*';/.test(swSource)) {
  throw new Error('sw.js generated build identity markers were not found');
}
const sw = swSource
  .replace(/const BUILD_ID = '[^']*';/, `const BUILD_ID = '${buildInfo.buildId}';`)
  .replace(/const CONTENT_HASH = '[^']*';/, `const CONTENT_HASH = '${buildInfo.contentHash}';`);
await writeFile(swPath, sw, 'utf8');

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
