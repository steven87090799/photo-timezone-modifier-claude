import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import {
  BUILD_INFO_SCHEMA_VERSION,
  isReleaseChannel,
  parseSemVer,
} from '../build-identity.mjs';

const REVISION = /^(?:[0-9a-f]{7,40}|unavailable)$/;
const UTC_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

const RUNTIME_ENTRIES = [
  'index.html',
  'main.js',
  'worker.js',
  'build-identity.mjs',
  'runtime-policy.js',
  'sw.js',
  'generation.json',
  'manifest.webmanifest',
  'fonts',
  'icons',
  'vendor',
];

async function walk(root, relative) {
  const absolute = path.join(root, relative);
  const info = await stat(absolute);
  if (info.isFile()) return [relative.split(path.sep).join('/')];
  if (!info.isDirectory()) throw new Error(`unsupported runtime asset type: ${relative}`);
  const children = (await readdir(absolute)).sort((a, b) => a.localeCompare(b, 'en'));
  return (await Promise.all(children.map(child => walk(root, path.join(relative, child))))).flat();
}

function normalizedRuntimeBytes(relative, bytes) {
  if (!['index.html', 'worker.js', 'sw.js'].includes(relative)) return bytes;
  let text = bytes.toString('utf8');
  if (relative === 'index.html') {
    text = text
      .replace(/(<meta name="nexpress-build-id" content=")[^"]*(")/, '$1__GENERATED_BUILD_ID__$2')
      .replace(/(<meta name="nexpress-content-hash" content=")[^"]*(")/, '$1sha256:__GENERATED_CONTENT_HASH__$2')
      .replace(/([?&]b=)[^&"']+/g, '$1__GENERATED_BUILD_ID__');
  } else if (relative === 'worker.js') {
    text = text.replace(/(runtime-policy\.js\?v=[^&"']+&b=)[^&"']+/, '$1__GENERATED_BUILD_ID__');
  } else {
    text = text
      .replace(/const BUILD_ID = '[^']*';/, "const BUILD_ID = '__GENERATED_BUILD_ID__';")
      .replace(/const CONTENT_HASH = '[^']*';/, "const CONTENT_HASH = 'sha256:__GENERATED_CONTENT_HASH__';");
  }
  return Buffer.from(text, 'utf8');
}

export async function runtimeAssetFiles(root) {
  return (await Promise.all(RUNTIME_ENTRIES.map(entry => walk(root, entry))))
    .flat().sort((a, b) => a.localeCompare(b, 'en'));
}

export async function computeRuntimeContent(root) {
  const files = await runtimeAssetFiles(root);
  const hash = createHash('sha256');
  for (const relative of files) {
    const sourceBytes = await readFile(path.join(root, relative));
    const bytes = normalizedRuntimeBytes(relative, sourceBytes);
    hash.update(relative, 'utf8');
    hash.update('\0');
    hash.update(String(bytes.byteLength), 'utf8');
    hash.update('\0');
    hash.update(bytes);
    hash.update('\0');
  }
  return { contentHash: `sha256:${hash.digest('hex')}`, assetCount: files.length, files };
}

export async function readReleaseAuthority(root) {
  const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  const generation = JSON.parse(await readFile(path.join(root, 'generation.json'), 'utf8'));
  const appVersion = pkg.version;
  const releaseGeneration = generation.generation;
  const channel = pkg.nexpressRelease?.channel;
  if (!parseSemVer(appVersion)) throw new Error('invalid canonical appVersion in package.json');
  if (!parseSemVer(releaseGeneration)) throw new Error('invalid canonical releaseGeneration in generation.json');
  if (generation.cache !== `nexpress-v${releaseGeneration}`) throw new Error('generation.json cache does not match its generation');
  if (!isReleaseChannel(channel)) throw new Error('invalid canonical channel in package.json');
  return { appVersion, releaseGeneration, channel };
}

export function resolveRevision(root, environment = process.env) {
  const explicit = environment.NEXPRESS_BUILD_REVISION;
  if (explicit) {
    const normalized = explicit.toLowerCase();
    if (!/^[0-9a-f]{7,40}$/.test(normalized)) {
      throw new Error('NEXPRESS_BUILD_REVISION must be a 7-40 character hexadecimal Git revision');
    }
    return normalized;
  }
  try {
    const revision = execFileSync('git', ['rev-parse', '--verify', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim().toLowerCase();
    return REVISION.test(revision) ? revision.slice(0, 12) : 'unavailable';
  } catch {
    return 'unavailable';
  }
}

export function resolveBuildTime(environment = process.env, now = () => new Date()) {
  const explicit = environment.NEXPRESS_BUILD_TIME;
  if (explicit) {
    const parsed = Date.parse(explicit);
    if (!UTC_ISO.test(explicit) || !Number.isFinite(parsed) || new Date(parsed).toISOString() !== explicit) {
      throw new Error('NEXPRESS_BUILD_TIME must be a canonical ISO-8601 UTC timestamp');
    }
    return explicit;
  }
  if (environment.SOURCE_DATE_EPOCH) {
    const seconds = Number(environment.SOURCE_DATE_EPOCH);
    if (!Number.isSafeInteger(seconds) || seconds < 0) {
      throw new Error('SOURCE_DATE_EPOCH must be a non-negative safe integer');
    }
    return new Date(seconds * 1000).toISOString();
  }
  return now().toISOString();
}

export function resolveChannel(canonicalChannel, environment = process.env) {
  const value = environment.NEXPRESS_RELEASE_CHANNEL || canonicalChannel;
  if (!isReleaseChannel(value)) {
    throw new Error('NEXPRESS_RELEASE_CHANNEL must be development, release-candidate, or production');
  }
  return value;
}

export function expectedBuildId(release, revision, contentHash) {
  const revisionLabel = revision === 'unavailable' ? 'dev' : revision.slice(0, 12);
  return `nexpress-${release.appVersion}-g${release.releaseGeneration}-${revisionLabel}-${contentHash.slice(7, 23)}`;
}

export async function createBuildInfo(root, options = {}) {
  const release = await readReleaseAuthority(root);
  const environment = options.environment || process.env;
  const revision = options.revision ?? resolveRevision(root, environment);
  const builtAt = options.builtAt ?? resolveBuildTime(environment);
  const channel = options.channel ?? resolveChannel(release.channel, environment);
  if (!REVISION.test(revision)) throw new Error('invalid resolved revision');
  if (!UTC_ISO.test(builtAt) || new Date(Date.parse(builtAt)).toISOString() !== builtAt) throw new Error('invalid resolved build time');
  if (!isReleaseChannel(channel)) throw new Error('invalid resolved channel');
  if (channel !== 'development' && revision === 'unavailable') throw new Error(`${channel} build metadata requires a Git revision`);
  const runtime = await computeRuntimeContent(root);
  return {
    schemaVersion: BUILD_INFO_SCHEMA_VERSION,
    appVersion: release.appVersion,
    releaseGeneration: release.releaseGeneration,
    buildId: expectedBuildId(release, revision, runtime.contentHash),
    revision,
    builtAt,
    channel,
    contentHash: runtime.contentHash,
    assetCount: runtime.assetCount,
  };
}
