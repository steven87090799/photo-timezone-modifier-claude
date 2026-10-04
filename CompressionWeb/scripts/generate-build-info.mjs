#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createBuildInfo, readReleaseAuthority } from './build-metadata-lib.mjs';
import { validateBuildInfo } from '../build-identity.mjs';

const root = process.env.NEXPRESS_ROOT
  ? path.resolve(process.env.NEXPRESS_ROOT)
  : path.join(import.meta.dirname, '..');
const release = await readReleaseAuthority(root);

const buildInfo = await createBuildInfo(root);
if (buildInfo.channel !== 'development' && buildInfo.revision === 'unavailable') {
  throw new Error(`${buildInfo.channel} build metadata requires a Git revision`);
}
const validation = validateBuildInfo(buildInfo);
if (!validation.ok) throw new Error(`generated build metadata is invalid: ${validation.errors.join(', ')}`);

await writeFile(path.join(root, 'build-info.json'), `${JSON.stringify(buildInfo, null, 2)}\n`, 'utf8');
console.log(`Generated ${buildInfo.buildId} (${buildInfo.assetCount} runtime assets).`);
