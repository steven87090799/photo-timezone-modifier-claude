// Native app worker: pixels arrive from macOS ImageIO; metadata is transferred
// and verified separately by Swift. No timezone, GPS or canvas modifications.
const moduleURL = new URL(import.meta.url);
const paths = { 'image/png': 'oxipng', 'image/webp': 'webp',
  'image/avif': 'avif', 'image/jxl': 'jxl' };
const modules = new Map();
async function encoder(format) {
  const name = paths[format];
  if (!name) throw new Error('不支援的壓縮格式');
  if (!modules.has(name)) modules.set(name, import(`./vendor/${name}.js`));
  return modules.get(name);
}
async function heif(image, options) {
  const response = await fetch(new URL('./native/heif/encode', moduleURL), {
    method: 'POST', body: image.data,
    headers: { 'Content-Type': 'application/octet-stream',
      'X-Image-Width': String(image.width), 'X-Image-Height': String(image.height),
      'X-Image-Quality': String(options.quality), 'X-Color-Source': options.nativeSourceToken,
      'X-Profile-Mode': options.profileMode }
  });
  if (!response.ok) throw new Error((await response.text()).slice(0, 300));
  return response.arrayBuffer();
}
async function encode(options) {
  const { id, rgba, width, height, format, type } = options;
  const preview = type === 'PREVIEW_ENCODE';
  const quality = Math.min(100, Math.max(1, Math.round(options.quality)));
  const image = new ImageData(new Uint8ClampedArray(rgba), width, height);
  self.postMessage({ type: 'TASK_PROGRESS', id, pct: 60, status: '編碼中' });
  if (format === 'image/heif') return heif(image, { ...options, quality });
  const codec = await encoder(format);
  switch (format) {
    case 'image/png':
      return codec.encode(image, { level: preview ? 2 : Math.round(quality * 6 / 100) });
    case 'image/webp':
      return codec.encode(image, { quality, method: preview ? 2 : 6, sns_strength: 50, use_sharp_yuv: 1 });
    case 'image/avif':
      return codec.encode(image, { cqLevel: Math.round((1 - quality / 100) * 63),
        speed: preview ? 10 : 6, sharpness: 1, subsample: quality >= 90 ? 3 : 1,
        chromaDeltaQ: true, tune: 2 });
    case 'image/jxl':
      return codec.encode(image, { quality, lossless: quality === 100,
        effort: preview || width * height > 20000000 ? 1 : width * height > 12000000 ? 3 : 5 });
    default: throw new Error('不支援的壓縮格式');
  }
}
self.onmessage = async ({ data }) => {
  if (!['COMPRESS', 'PREVIEW_ENCODE'].includes(data.type)) return;
  try {
    const buffer = await encode(data);
    if (!buffer?.byteLength) throw new Error('編碼器產生空白輸出');
    self.postMessage({ type: data.type === 'PREVIEW_ENCODE' ? 'PREVIEW_DONE' : 'TASK_DONE',
      id: data.id, buffer, format: data.format }, [buffer]);
  } catch (error) {
    self.postMessage({ type: data.type === 'PREVIEW_ENCODE' ? 'PREVIEW_ERROR' : 'TASK_ERROR',
      id: data.id, error: data.format === 'image/jxl' && data.quality === 100
        ? 'JPEG XL 無損編碼失敗；請降低品質後重試。未自動改成有損輸出。' : error.message });
  }
};
try {
  const response = await fetch(new URL('./native/health', moduleURL));
  if (!response.ok) throw new Error('原生影像服務無法使用');
  const health = await response.json();
  self.postMessage({ type: 'READY', capabilities: {
    formats: { ...Object.fromEntries(Object.keys(paths).map(format => [format, true])), 'image/heif': health.heif }
  }});
} catch (error) { self.postMessage({ type: 'INIT_ERROR', error: error.message }); }
