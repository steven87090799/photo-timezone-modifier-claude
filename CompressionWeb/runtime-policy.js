/** Pure runtime policies shared by the Worker and deterministic browser tests. */

export function shiftExifDateString(value, minutes) {
  const m = /^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$/.exec(String(value));
  if (!m) return null;
  const [year, month, day, hour, minute, second] = m.slice(1).map(Number);
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1 || day > 31 ||
      hour > 23 || minute > 59 || second > 59 || !Number.isFinite(minutes)) return null;

  const base = new Date(0);
  base.setUTCFullYear(year, month - 1, day);
  base.setUTCHours(hour, minute, second, 0);
  if (base.getUTCFullYear() !== year || base.getUTCMonth() !== month - 1 ||
      base.getUTCDate() !== day || base.getUTCHours() !== hour ||
      base.getUTCMinutes() !== minute || base.getUTCSeconds() !== second) return null;

  const t = base.getTime() + minutes * 60000;
  if (!Number.isFinite(t)) return null;
  const d = new Date(t);
  if (d.getUTCFullYear() < 1 || d.getUTCFullYear() > 9999) return null;
  const p = (n, width = 2) => String(n).padStart(width, '0');
  return `${p(d.getUTCFullYear(), 4)}:${p(d.getUTCMonth() + 1)}:${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`;
}

export function sniffGifAnimation(view) {
  if (!(view instanceof Uint8Array) || view.length <= 13 ||
      view[0] !== 0x47 || view[1] !== 0x49 || view[2] !== 0x46) return false;

  const skipSubBlocks = (start) => {
    let off = start;
    while (off < view.length) {
      const size = view[off++];
      if (size === 0) return off;
      if (off + size > view.length) return -1;
      off += size;
    }
    return -1;
  };

  const packed = view[10];
  let off = 13;
  if (packed & 0x80) off += 3 * (1 << ((packed & 0x07) + 1));
  let frames = 0;
  while (off < view.length) {
    const marker = view[off++];
    if (marker === 0x3B) return false;
    if (marker === 0x21) {
      if (off >= view.length) return false;
      off++;
      off = skipSubBlocks(off);
      if (off < 0) return false;
      continue;
    }
    if (marker !== 0x2C || off + 9 > view.length) return false;
    const descriptorPacked = view[off + 8];
    off += 9;
    if (descriptorPacked & 0x80) off += 3 * (1 << ((descriptorPacked & 0x07) + 1));
    if (off >= view.length) return false;
    off++;
    off = skipSubBlocks(off);
    if (off < 0) return false;
    frames++;
    if (frames >= 2) return true;
  }
  return false;
}
