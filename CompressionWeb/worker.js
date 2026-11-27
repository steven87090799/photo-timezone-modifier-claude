// ImageIO supplies pixels. Swift transfers and verifies metadata after encoding.
import { encode } from './vendor/oxipng.js';

self.onmessage = async ({ data }) => {
  if (data.type !== 'COMPRESS') return;
  const { id, rgba, width, height, format, quality, preview } = data;
  try {
    if (format !== 'image/png') throw new Error('不支援的壓縮格式');
    const image = new ImageData(new Uint8ClampedArray(rgba), width, height);
    const effort = Math.round((Math.min(100, Math.max(1, quality)) / 100) ** 2 * 6);
    self.postMessage({ type: 'TASK_PROGRESS', id, pct: 60, status: '編碼中' });
    const buffer = await encode(image, { level: preview ? 2 : effort });
    if (!buffer?.byteLength) throw new Error('編碼器產生空白輸出');
    self.postMessage({ type: 'TASK_DONE', id, buffer }, [buffer]);
  } catch (error) {
    self.postMessage({ type: 'TASK_ERROR', id, error: error?.message || '編碼失敗' });
  }
};

self.postMessage({ type: 'READY', capabilities: { formats: { 'image/png': true } } });
