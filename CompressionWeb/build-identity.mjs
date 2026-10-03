/** Pure browser/Node build-identity validation. Contains no release values. */

export const BUILD_INFO_SCHEMA_VERSION = 1;
export const RUNTIME_IDENTITY_STATES = Object.freeze([
  'VERIFIED', 'UNVERIFIED', 'MISMATCH', 'UNAVAILABLE',
]);

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;
const BUILD_ID = /^[0-9A-Za-z][0-9A-Za-z.+_-]{7,159}$/;
const REVISION = /^(?:[0-9a-f]{7,40}|unavailable)$/;
const CONTENT_HASH = /^sha256:[0-9a-f]{64}$/;
const UTC_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const CHANNELS = new Set(['development', 'release-candidate', 'production']);

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

export function parseSemVer(value) {
  if (typeof value !== 'string') return null;
  const match = value.match(SEMVER);
  if (!match) return null;
  return Object.freeze({
    raw: value,
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease: match[4] ? Object.freeze(match[4].split('.')) : Object.freeze([]),
    build: match[5] || null,
  });
}

export function compareReleaseGenerations(left, right) {
  const a = parseSemVer(left);
  const b = parseSemVer(right);
  if (!a || !b) return null;
  for (const key of ['major', 'minor', 'patch']) {
    if (a[key] !== b[key]) return a[key] < b[key] ? -1 : 1;
  }
  if (!a.prerelease.length || !b.prerelease.length) {
    return a.prerelease.length === b.prerelease.length ? 0 : (a.prerelease.length ? -1 : 1);
  }
  const count = Math.max(a.prerelease.length, b.prerelease.length);
  for (let index = 0; index < count; index++) {
    const ai = a.prerelease[index];
    const bi = b.prerelease[index];
    if (ai === undefined || bi === undefined) return ai === undefined ? -1 : 1;
    if (ai === bi) continue;
    const an = /^\d+$/.test(ai);
    const bn = /^\d+$/.test(bi);
    if (an && bn) return Number(ai) < Number(bi) ? -1 : 1;
    if (an !== bn) return an ? -1 : 1;
    return ai < bi ? -1 : 1;
  }
  return 0;
}

export function isReleaseChannel(value) {
  return typeof value === 'string' && CHANNELS.has(value);
}

export function validateBuildInfo(candidate) {
  const errors = [];
  if (!isPlainObject(candidate)) return { ok: false, errors: ['metadata must be an object'], value: null };

  if (candidate.schemaVersion !== BUILD_INFO_SCHEMA_VERSION) errors.push('unsupported schemaVersion');
  if (!parseSemVer(candidate.appVersion)) errors.push('invalid appVersion');
  if (!parseSemVer(candidate.releaseGeneration)) errors.push('invalid releaseGeneration');
  if (!BUILD_ID.test(candidate.buildId || '')) errors.push('invalid buildId');
  if (!REVISION.test(candidate.revision || '')) errors.push('invalid revision');
  if (!isReleaseChannel(candidate.channel)) errors.push('invalid channel');
  if (!CONTENT_HASH.test(candidate.contentHash || '')) errors.push('invalid contentHash');
  if (!Number.isSafeInteger(candidate.assetCount) || candidate.assetCount <= 0) errors.push('invalid assetCount');
  const builtAtMs = Date.parse(candidate.builtAt);
  if (!UTC_ISO.test(candidate.builtAt || '') || !Number.isFinite(builtAtMs)
      || new Date(builtAtMs).toISOString() !== candidate.builtAt) errors.push('invalid builtAt');
  if (candidate.channel !== 'development' && candidate.revision === 'unavailable') {
    errors.push(`${candidate.channel} metadata requires a Git revision`);
  }

  if (errors.length) return { ok: false, errors, value: null };
  return {
    ok: true,
    errors: [],
    value: Object.freeze({
      schemaVersion: candidate.schemaVersion,
      appVersion: candidate.appVersion,
      releaseGeneration: candidate.releaseGeneration,
      buildId: candidate.buildId,
      revision: candidate.revision,
      builtAt: candidate.builtAt,
      channel: candidate.channel,
      contentHash: candidate.contentHash,
      assetCount: candidate.assetCount,
    }),
  };
}

export function validateRuntimeIdentity(candidate) {
  if (!isPlainObject(candidate)) return { ok: false, errors: ['runtime identity must be an object'], value: null };
  const errors = [];
  if (!parseSemVer(candidate.releaseGeneration)) errors.push('invalid runtime releaseGeneration');
  if (!BUILD_ID.test(candidate.buildId || '')) errors.push('invalid runtime buildId');
  if (!CONTENT_HASH.test(candidate.contentHash || '')) errors.push('invalid runtime contentHash');
  return errors.length ? { ok: false, errors, value: null } : {
    ok: true,
    errors: [],
    value: Object.freeze({
      releaseGeneration: candidate.releaseGeneration,
      buildId: candidate.buildId,
      contentHash: candidate.contentHash,
    }),
  };
}

export function classifyBuildIdentity(runtimeIdentity, candidate, loadFailure = null) {
  const expected = validateRuntimeIdentity(runtimeIdentity);
  if (!expected.ok) return { state: 'UNVERIFIED', reason: expected.errors.join('; '), current: null };
  if (loadFailure) {
    const state = loadFailure.kind === 'unavailable' ? 'UNAVAILABLE' : 'UNVERIFIED';
    return { state, reason: String(loadFailure.message || loadFailure), current: null };
  }
  if (candidate == null) return { state: 'UNAVAILABLE', reason: 'build metadata is unavailable', current: null };

  const validated = validateBuildInfo(candidate);
  if (!validated.ok) return { state: 'UNVERIFIED', reason: validated.errors.join('; '), current: null };
  if (validated.value.releaseGeneration !== expected.value.releaseGeneration
      || validated.value.buildId !== expected.value.buildId
      || validated.value.contentHash !== expected.value.contentHash) {
    return {
      state: 'MISMATCH',
      reason: 'metadata does not match the page-bound generation, build ID, and content hash',
      current: null,
    };
  }
  return { state: 'VERIFIED', reason: 'metadata matches the page-bound runtime identity', current: validated.value };
}

export function sameBuildIdentity(left, right) {
  const a = validateBuildInfo(left);
  const b = validateBuildInfo(right);
  return a.ok && b.ok
    && a.value.releaseGeneration === b.value.releaseGeneration
    && a.value.buildId === b.value.buildId
    && a.value.contentHash === b.value.contentHash;
}

export function validateServiceWorkerStatus(candidate) {
  if (!isPlainObject(candidate)) return { ok: false, errors: ['status must be an object'], value: null };
  const errors = [];
  if (candidate.type !== 'NX_STATUS') errors.push('invalid status type');
  if (!parseSemVer(candidate.generation)) errors.push('invalid status generation');
  if (!BUILD_ID.test(candidate.buildId || '')) errors.push('invalid status buildId');
  if (!CONTENT_HASH.test(candidate.contentHash || '')) errors.push('invalid status contentHash');
  if (candidate.cacheName !== `nexpress-${candidate.buildId}`) errors.push('status cacheName does not match buildId');
  if (typeof candidate.offlineReady !== 'boolean') errors.push('offlineReady must be boolean');
  if (!Array.isArray(candidate.missing) || candidate.missing.length > 128
      || candidate.missing.some(item => typeof item !== 'string' || item.length > 512)) errors.push('invalid missing list');
  const buildInfo = validateBuildInfo(candidate.buildInfo);
  if (!buildInfo.ok) errors.push(`invalid cached buildInfo: ${buildInfo.errors.join(', ')}`);
  if (candidate.offlineReady === true && candidate.missing?.length !== 0) errors.push('offlineReady conflicts with missing list');
  return errors.length ? { ok: false, errors, value: null } : {
    ok: true,
    errors: [],
    value: Object.freeze({
      type: candidate.type,
      generation: candidate.generation,
      buildId: candidate.buildId,
      contentHash: candidate.contentHash,
      cacheName: candidate.cacheName,
      offlineReady: candidate.offlineReady,
      missing: Object.freeze([...candidate.missing]),
      buildInfo: buildInfo.value,
    }),
  };
}
