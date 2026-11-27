// Invisible runtime. Every user control, progress display and output action is native SwiftUI.
const bridge = message => window.webkit.messageHandlers.compression.postMessage(message);
const build = await fetch('./build-info.json', { cache: 'no-store' }).then(response => response.json());
const workerURL = `./worker.js?v=${encodeURIComponent(build.appVersion)}&b=${encodeURIComponent(build.buildId)}`;
const pool = new Set();
const jobs = new Map();

function createWorker(format = null) {
  const worker = new Worker(workerURL, { type: 'module' });
  const entry = { worker, format, idleTimer: null, busy: false, pending: null };
  let readyResolve, readyReject;
  entry.ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
  const initTimeout = setTimeout(() => readyReject(new Error('壓縮編碼器載入逾時')), 60000);
  worker.onmessage = ({ data }) => {
    if (data.type === 'READY') { clearTimeout(initTimeout); readyResolve(data.capabilities); }
    const task = entry.pending;
    if (!task || data.id !== task.id) return;
    if (data.type === 'TASK_PROGRESS') {
      bridge({ type: 'progress', id: task.id, pct: Math.min(90, data.pct || 0), status: data.status || '處理中' });
    } else if (data.type === 'TASK_DONE') {
      task.resolve(data);
    } else if (data.type === 'TASK_ERROR') {
      task.reject(new Error(data.error));
    }
  };
  worker.onerror = event => entry.dispose(new Error(event.message || '壓縮工作程序已中止'));
  entry.dispose = (error = new Error('壓縮工作程序已結束')) => {
    if (!pool.delete(entry)) return;
    clearTimeout(initTimeout);
    clearTimeout(entry.idleTimer);
    readyReject(error);
    entry.pending?.reject(error);
    worker.terminate();
  };
  pool.add(entry);
  return entry;
}

async function attempt(options, credential, signal) {
  // Recycle idle workers when changing format to release their WASM heaps.
  let entry;
  for (const worker of pool) {
    if (worker.busy) continue;
    if (worker.format !== options.format) worker.dispose();
    else entry ??= worker;
  }
  entry ??= createWorker(options.format);
  clearTimeout(entry.idleTimer);
  entry.busy = true;
  const abort = () => entry.dispose(new Error('已取消'));
  signal.addEventListener('abort', abort, { once: true });
  const headers = { 'X-PhotoTimezone-Session': credential };
  const request = { mode: 'same-origin', credentials: 'omit', redirect: 'error', signal };
  try {
    signal.throwIfAborted();
    const capabilities = await entry.ready;
    if (!capabilities.formats[options.format]) throw new Error('此格式的編碼器無法使用');
    bridge({ type: 'progress', id: options.id, pct: 5, status: 'macOS 原生解碼' });
    const raster = await fetch(`/native/raster/${options.id}`, { ...request, headers });
    if (!raster.ok) throw new Error(await raster.text());
    const width = Number(raster.headers.get('X-Image-Width'));
    const height = Number(raster.headers.get('X-Image-Height'));
    const frames = Number(raster.headers.get('X-Frame-Count'));
    const profileMode = raster.headers.get('X-Profile-Mode');
    const rgba = await raster.arrayBuffer();
    signal.throwIfAborted();
    const task = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('壓縮逾時，已停止這張圖片')), options.preview ? 90000 : 600000);
      entry.pending = { id: options.id,
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); } };
      try {
        entry.worker.postMessage({ type: 'COMPRESS', id: options.id, format: options.format,
          quality: options.quality, preview: options.preview, rgba, width, height }, [rgba]);
      } catch (error) { entry.pending.reject(error); }
    });
    signal.throwIfAborted();
    const response = await fetch(`/native/result/${options.id}`, { ...request, method: 'POST',
      headers: { ...headers, 'Content-Type': 'application/octet-stream' }, body: task.buffer });
    if (!response.ok) throw new Error(await response.text());
    return { width, height, frames, profileMode, quality: options.quality };
  } catch (error) {
    entry.dispose();
    throw error;
  } finally {
    signal.removeEventListener('abort', abort);
    entry.busy = false;
    entry.pending = null;
    if (pool.has(entry)) entry.idleTimer = setTimeout(() => entry.dispose(), 15000);
  }
}

window.compressionEngine = {
  async perform(options, credential) {
    const controller = new AbortController();
    jobs.set(options.id, controller);
    try { return await attempt(options, credential, controller.signal); }
    finally { jobs.delete(options.id); }
  },
  cancel(id) { jobs.get(id)?.abort(); },
  cancelAll() {
    for (const controller of jobs.values()) controller.abort();
    for (const entry of pool) if (entry.format !== null) entry.dispose();
  }
};

try {
  const probe = createWorker();
  try {
    const ready = await probe.ready;
    bridge({ type: 'ready', formats: Object.keys(ready.formats) });
  } finally { probe.dispose(); }
} catch (error) { bridge({ type: 'error', message: error.message }); }
