import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('cancelling settles Worker startup, raster transfer, encoding and result upload', { timeout: 2000 }, async () => {
  const workers = [];
  const messages = [];
  const gate = () => {
    let signal;
    const promise = new Promise(resolve => { signal = resolve; });
    return { promise, signal };
  };
  const reading = gate();
  const encoding = gate();
  const uploading = gate();
  const aborted = signal => new Promise((_, reject) => signal.addEventListener(
    'abort', () => reject(signal.reason), { once: true }));
  globalThis.window = { webkit: { messageHandlers: { compression: { postMessage: value => messages.push(value) } } } };
  globalThis.Worker = class {
    constructor() {
      workers.push(this);
      if (workers.length !== 2) {
        queueMicrotask(() => this.onmessage({ data: { type: 'READY', capabilities: { formats: { 'image/png': true } } } }));
      }
    }
    postMessage(task) {
      if (task.id === 'encoding-job') {
        encoding.signal();
        return;
      }
      assert.equal(task.id, 'upload-job');
      queueMicrotask(() => this.onmessage({ data: {
        id: task.id, type: 'TASK_DONE', buffer: new ArrayBuffer(2),
      } }));
    }
    terminate() { this.terminated = true; }
  };

  globalThis.fetch = async (url, options) => {
    if (url === './build-info.json') return { json: async () => ({ appVersion: 'test', buildId: 'fixture' }) };
    assert.equal(options.headers['X-PhotoTimezone-Session'], 'fixture-credential');
    assert.equal(options.mode, 'same-origin');
    if (url === '/native/raster/next-job') {
      reading.signal();
      return aborted(options.signal);
    }
    if (url === '/native/result/upload-job') {
      assert.equal(options.method, 'POST');
      uploading.signal();
      return aborted(options.signal);
    }
    assert.match(url, /^\/native\/raster\/(encoding-job|upload-job)$/);
    return { ok: true, headers: new Map([
      ['X-Image-Width', '1'], ['X-Image-Height', '1'], ['X-Frame-Count', '1'], ['X-Profile-Mode', 'srgb'],
    ]), arrayBuffer: async () => new ArrayBuffer(4) };
  };

  const source = await readFile(new URL('../../CompressionWeb/native-engine.js', import.meta.url));
  await import('data:text/javascript;base64,' + source.toString('base64'));
  assert.deepEqual(messages, [{ type: 'ready', formats: ['image/png'] }]);

  const engine = globalThis.window.compressionEngine;
  const waitingForWorker = engine.perform({ id: 'starting-job', format: 'image/png', preview: true }, 'fixture-credential');
  const rejectedWorker = assert.rejects(waitingForWorker, /已取消/);
  engine.cancelAll();
  await rejectedWorker;
  assert.equal(workers[1].terminated, true);

  const fetching = engine.perform({ id: 'next-job', format: 'image/png', preview: true }, 'fixture-credential');
  const rejectedFetch = assert.rejects(fetching, { name: 'AbortError' });
  await reading.promise;
  engine.cancel('next-job');
  await rejectedFetch;
  assert.equal(workers[2].terminated, true);

  const encode = engine.perform({ id: 'encoding-job', format: 'image/png', preview: true }, 'fixture-credential');
  const rejectedEncode = assert.rejects(encode, /已取消/);
  await encoding.promise;
  engine.cancel('encoding-job');
  await rejectedEncode;
  assert.equal(workers[3].terminated, true);

  const upload = engine.perform({ id: 'upload-job', format: 'image/png', preview: true }, 'fixture-credential');
  const rejectedUpload = assert.rejects(upload, { name: 'AbortError' });
  await uploading.promise;
  engine.cancel('upload-job');
  await rejectedUpload;
  assert.equal(workers[4].terminated, true);

});
