// Invisible runtime. Every user control, progress display and output action is native SwiftUI.
const bridge = message => window.webkit.messageHandlers.compression.postMessage(message);
const build = await fetch('./build-info.json', { cache: 'no-store' }).then(r => r.json());
const workerURL = `./worker.js?v=${encodeURIComponent(build.appVersion)}&b=${encodeURIComponent(build.buildId)}`;
const pool = [];
let generation = 0;

function createWorker(format = null) {
  const entry = { idleTimer: null, worker: new Worker(workerURL, { type: 'module' }), busy: false, pending: null };
  entry.format = format;
  let readyResolve, readyReject;
  entry.ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
  const initTimeout = setTimeout(() => readyReject(new Error('壓縮編碼器載入逾時')), 60000);
  entry.worker.onmessage = ({ data }) => {
    if (data.type === 'READY') { clearTimeout(initTimeout); readyResolve(data.capabilities); }
    if (data.type === 'INIT_ERROR') { clearTimeout(initTimeout); readyReject(new Error(data.error)); }
    const task = entry.pending;
    if (!task || data.id !== task.id) return;
    if (data.type === 'TASK_START' || data.type === 'TASK_PROGRESS') {
      bridge({ type: 'progress', id: task.id, pct: Math.min(90, data.pct || 0), status: data.status || '處理中' });
    } else if (data.type === 'TASK_DONE' || data.type === 'PREVIEW_DONE') { task.resolve(data); }
    else if (data.type === 'TASK_ERROR' || data.type === 'PREVIEW_ERROR' || data.type === 'TASK_JXL_NEAR_LOSSLESS_RETRY') { task.reject(new Error(data.error)); }
  };
  entry.worker.onerror = event => {
    clearTimeout(initTimeout);
    const error = new Error(event.message || '壓縮工作程序已中止');
    readyReject(error); entry.pending?.reject(error);
  };
  entry.dispose = () => { clearTimeout(initTimeout); clearTimeout(entry.idleTimer); entry.worker.terminate(); };
  pool.push(entry);
  return entry;
}

async function attempt(options, currentGeneration) {
  // A worker retains each loaded WASM encoder. Recycle idle workers when the
  // user switches format so large PNG/AVIF/JXL heaps do not accumulate.
  for (let index = pool.length - 1; index >= 0; index--) {
    const worker = pool[index];
    if (!worker.busy && worker.format && worker.format !== options.format) {
      worker.dispose(); pool.splice(index, 1);
    }
  }
  const entry = pool.find(worker => !worker.busy && (!worker.format || worker.format === options.format)) || createWorker(options.format);
  entry.format = options.format;
  clearTimeout(entry.idleTimer); entry.busy = true;
  try {
    const capabilities = await entry.ready;
    if (!capabilities.formats[options.format]) throw new Error('此格式的編碼器無法使用');
    bridge({ type: 'progress', id: options.id, pct: 5, status: 'macOS 原生解碼' });
    const profile = options.preserveProfile ? 'original' : 'srgb';
    const rasterResponse = await fetch(`/native/raster/${options.id}?size=${options.preview ? 900 : 0}&profile=${profile}`);
    if (!rasterResponse.ok) throw new Error(await rasterResponse.text());
    const width = Number(rasterResponse.headers.get('X-Image-Width'));
    const height = Number(rasterResponse.headers.get('X-Image-Height'));
    const frames = Number(rasterResponse.headers.get('X-Frame-Count'));
    const profileMode = rasterResponse.headers.get('X-Profile-Mode');
    const rgba = await rasterResponse.arrayBuffer();
    // Source metadata is transferred and verified by ExifTool after encoding.
    const file = options.preview ? null : new File([], options.name);
    if (currentGeneration !== generation) throw new Error('已取消');
    const task = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('壓縮逾時，已停止這張圖片')), options.preview ? 90000 : 600000);
      entry.pending = { id: options.id,
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); } };
      entry.worker.postMessage({ type: options.preview ? 'PREVIEW_ENCODE' : 'COMPRESS',
        id: options.id, file, format: options.format, quality: options.quality,
        rgba, width, height, nativeSourceToken: options.id, profileMode,
        modifyTz: false, timeShiftMinutes: 0 }, [rgba]);
    });
    if (currentGeneration !== generation) throw new Error('已取消');
    const response = await fetch(`/native/result/${options.id}`, { method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream' }, body: task.buffer });
    if (!response.ok) throw new Error(await response.text());
    return { width, height, frames, profileMode, quality: options.quality };
  } catch (error) {
    entry.dispose();
    const index = pool.indexOf(entry);
    if (index >= 0) pool.splice(index, 1);
    throw error;
  } finally {
    entry.busy = false; entry.pending = null;
    if (pool.includes(entry)) entry.idleTimer = setTimeout(() => {
      if (entry.busy) return;
      entry.dispose();
      const index = pool.indexOf(entry);
      if (index >= 0) pool.splice(index, 1);
    }, 15000);
  }
}

window.compressionEngine = {
  async perform(options) {
    const currentGeneration = generation;
    return attempt(options, currentGeneration);
  },
  cancelAll() {
    generation++;
    for (const entry of pool) { entry.pending?.reject(new Error('已取消')); entry.dispose(); }
    pool.length = 0;
  }
};

try {
  const probe = createWorker();
  const ready = await probe.ready;
  probe.dispose();
  pool.splice(pool.indexOf(probe), 1);
  bridge({ type: 'ready', formats: Object.entries(ready.formats).filter(([, enabled]) => enabled).map(([format]) => format) });
} catch (error) { bridge({ type: 'error', message: error.message }); }
