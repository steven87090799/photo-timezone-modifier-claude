import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { readFileSync } from 'node:fs';
import test from 'node:test';
import assert from 'node:assert/strict';

test('build identity is checked against an independent revision and channel', () => {
  const check = new URL('../../CompressionWeb/scripts/check-build-info.mjs', import.meta.url);
  const info = JSON.parse(readFileSync(new URL('../../CompressionWeb/build-info.json', import.meta.url), 'utf8'));
  const run = (revision, channel) => spawnSync(process.execPath, [fileURLToPath(check)], {
    env: { ...process.env, NEXPRESS_BUILD_REVISION: revision, NEXPRESS_RELEASE_CHANNEL: channel },
    encoding: 'utf8',
  });
  assert.equal(run(info.revision, info.channel).status, 0);
  const invalid = run(info.revision[0] === '0' ? '123456789abc' : '000000000000', 'production');
  assert.equal(invalid.status, 1);
  assert.match(invalid.stderr, /revision: expected/);
  assert.match(invalid.stderr, /channel: expected production/);
});
