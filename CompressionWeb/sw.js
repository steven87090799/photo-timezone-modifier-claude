/**
 * sw.js — NEXPRESS Service Worker(PWA 完全離線架構)
 *
 * 策略(依 V6 稽核決策):
 *  - 版本化快取:CACHE_VERSION 變更 → activate 時清掉舊快取
 *  - 不用 skipWaiting:避免 main.js ↔ worker.js/vendor 在同一 session 內版本錯配;
 *    新版本下載完成後由頁面提示「重新整理後生效」
 *  - vendor / fonts / icons:cache-first(重資產,版本 bump 才更新)
 *  - app shell(index/main/worker/manifest):network-first + 快取 fallback(離線可用)
 *  - versioned JS requests use exact query-string identity; an old controller
 *    must never satisfy a new generation from an old cache entry
 *  - 攔截範圍涵蓋 module dedicated worker 的主腳本、其 dynamic import 與 wasm fetch
 *    (Chromium ≥105 / Firefox ≥114 / Safari ≥16 均支援)
 */

const CACHE_VERSION = 'v3.2.1';
const BUILD_ID = 'nexpress-3.2.1-g3.2.1-04361249b1d3-f4fee95b300cb982';
const CONTENT_HASH = 'sha256:f4fee95b300cb982c05b5c126c464254f5525c227f2ffdc553882931a1b29161';
const APP_VERSION = CACHE_VERSION.slice(1);
const CACHE_NAME = `nexpress-${BUILD_ID}`;
const versioned = (assetPath) => `${assetPath}?v=${encodeURIComponent(APP_VERSION)}&b=${encodeURIComponent(BUILD_ID)}`;

// 只預快取實際使用的編碼資產；HEIF 由 macOS ImageIO 處理。
const PRECACHE_URLS = [
  './',
  './index.html',
  './generation.json',
  versioned('./build-info.json'),
  versioned('./build-identity.mjs'),
  versioned('./main.js'),
  versioned('./worker.js'),
  versioned('./runtime-policy.js'),
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  // ── vendor:JS glue ──
  versioned('./vendor/jpeg.js'),
  versioned('./vendor/png.js'),
  versioned('./vendor/webp.js'),
  versioned('./vendor/avif.js'),
  versioned('./vendor/jxl.js'),
  versioned('./vendor/piexif.js'),
  versioned('./vendor/jszip.min.js'),
  // ── vendor:WASM(glue 以 import.meta.url 相對路徑抓取)──
  './vendor/mozjpeg_enc.wasm',
  './vendor/mozjpeg_dec.wasm',
  './vendor/squoosh_png_bg.wasm',
  './vendor/webp_enc.wasm',
  './vendor/webp_enc_simd.wasm',
  './vendor/webp_dec.wasm',
  './vendor/avif_enc.wasm',
  './vendor/avif_enc_mt.wasm',
  './vendor/avif_dec.wasm',
  './vendor/jxl_enc.wasm',
  // ── fonts ──
  './fonts/jetbrains-mono-latin-300-normal.woff2',
  './fonts/jetbrains-mono-latin-400-normal.woff2',
  './fonts/jetbrains-mono-latin-500-normal.woff2',
  './fonts/jetbrains-mono-latin-600-normal.woff2',
  './fonts/jetbrains-mono-latin-700-normal.woff2',
  './fonts/orbitron-latin-500-normal.woff2',
  './fonts/orbitron-latin-600-normal.woff2',
  './fonts/orbitron-latin-700-normal.woff2',
  './fonts/orbitron-latin-900-normal.woff2',
];

// cache-first 的路徑前綴(重資產,內容隨版本 bump 更新)
const CACHE_FIRST_PATTERN = /\/(vendor|fonts|icons)\//;
const OFFLINE_SENTINELS = [
  './',
  versioned('./build-info.json'),
  versioned('./build-identity.mjs'),
  versioned('./main.js'),
  versioned('./worker.js'),
  versioned('./runtime-policy.js'),
  versioned('./vendor/jpeg.js'),
  './vendor/mozjpeg_enc.wasm',
  versioned('./vendor/jszip.min.js'),
  './generation.json',
];

async function inspectGenerationCache(cache) {
  const checks = await Promise.all(OFFLINE_SENTINELS.map(async assetPath => [assetPath, Boolean(await cache.match(assetPath))]));
  const missing = checks.filter(([, present]) => !present).map(([assetPath]) => assetPath);
  let buildInfo = null;
  try {
    const response = await cache.match(versioned('./build-info.json'));
    if (!response || !/^application\/json(?:;|$)/i.test(response.headers.get('content-type') || '')) {
      missing.push('build-info.json content type');
    } else {
      buildInfo = await response.json();
      if (buildInfo?.releaseGeneration !== APP_VERSION
          || buildInfo?.buildId !== BUILD_ID
          || buildInfo?.contentHash !== CONTENT_HASH) missing.push('build-info.json identity mismatch');
    }
  } catch {
    missing.push('build-info.json malformed');
  }
  try {
    const shell = await cache.match('./');
    const html = shell ? await shell.text() : '';
    if (!html.includes(`<meta name="nexpress-release-generation" content="${APP_VERSION}">`)
        || !html.includes(`<meta name="nexpress-build-id" content="${BUILD_ID}">`)
        || !html.includes(`<meta name="nexpress-content-hash" content="${CONTENT_HASH}">`)
        || !html.includes(`./main.js?v=${APP_VERSION}&b=${BUILD_ID}`)) missing.push('cached shell identity mismatch');
  } catch {
    missing.push('cached shell malformed');
  }
  return { missing: [...new Set(missing)], buildInfo };
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(async (cache) => {
      await cache.addAll(PRECACHE_URLS);
      const inspection = await inspectGenerationCache(cache);
      if (inspection.missing.length) throw new Error(`incoherent release cache: ${inspection.missing.join(', ')}`);
    })
    // Any rejected request fails installation loudly. Cache.addAll may have
    // written earlier entries, so readiness separately verifies every sentinel;
    // the inactive generation can never be reported as offline-ready.
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys.filter((k) => k.startsWith('nexpress-') && k !== CACHE_NAME).map((k) => caches.delete(k))
      );
      await self.clients.claim(); // 首次安裝立即接管(無 skipWaiting,更新仍需 reload)
    })()
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return; // webhook 等跨域請求一律放行

  // 導航請求:network-first + 成功時回寫快取,離線 fallback 到快取的 index.html。
  // 回寫讓 shell 與 main.js/worker.js 的更新政策對稱:否則部署新版而未 bump
  // CACHE_VERSION 時,離線會拿到「安裝時的舊 index + 執行期更新過的新 main.js」錯配組合
  if (request.mode === 'navigate') {
    event.respondWith(
      (async () => {
        const cache = await caches.open(CACHE_NAME);
        const cached = await cache.match(new URL('./', self.registration.scope).href);
        try {
          const res = await fetch(request);
          if (res.type === 'error' || res.status === 0) throw new Error('network unavailable');
          if (res.ok) {
            const html = await res.clone().text();
            const sameBuild = html.includes(`<meta name="nexpress-build-id" content="${BUILD_ID}">`)
              && html.includes(`<meta name="nexpress-content-hash" content="${CONTENT_HASH}">`);
            // An old controller must keep serving its own shell until reload activates the waiting build.
            if (!sameBuild) return cached || Response.error();
            // Store successful navigations under the scope root. Some static
            // servers redirect /index.html to a clean URL; a cached redirected
            // response cannot safely satisfy a later navigation request.
            try { await cache.put(new URL('./', self.registration.scope).href, res.clone()); }
            catch (error) { console.warn('[NEXPRESS SW] navigation cache update failed:', error); }
          }
          return res;
        } catch {
          return cached || Response.error();
        }
      })()
    );
    return;
  }

  const pageBoundRequest = url.searchParams.get('b') === BUILD_ID;
  if (CACHE_FIRST_PATTERN.test(url.pathname) || pageBoundRequest) {
    // 重資產:cache-first
    event.respondWith(
      (async () => {
        const cache = await caches.open(CACHE_NAME);
        const cached = await cache.match(request);
        if (cached) return cached;
        const res = await fetch(request);
        if (res.ok) {
          try { await cache.put(request, res.clone()); }
          catch (error) { console.warn('[NEXPRESS SW] bound asset cache update failed:', error); }
        }
        return res;
      })()
    );
    return;
  }

  // app shell(main.js / worker.js / manifest 等):network-first + 快取 fallback
  event.respondWith(
    (async () => {
      try {
        const res = await fetch(request);
        if (res.ok) {
          const cache = await caches.open(CACHE_NAME);
          try { await cache.put(request, res.clone()); }
          catch (error) { console.warn('[NEXPRESS SW] shell cache update failed:', error); }
        }
        return res;
      } catch {
        const cache = await caches.open(CACHE_NAME);
        const cached = await cache.match(request);
        if (cached) return cached;
        throw new Error(`offline and not cached: ${url.pathname}`);
      }
    })()
  );
});

self.addEventListener('message', (event) => {
  if (event.data?.type !== 'NX_GET_STATUS' || !event.ports?.[0]) return;
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    const { missing, buildInfo } = await inspectGenerationCache(cache);
    event.ports[0].postMessage({
      type: 'NX_STATUS',
      generation: APP_VERSION,
      buildId: BUILD_ID,
      contentHash: CONTENT_HASH,
      cacheName: CACHE_NAME,
      offlineReady: missing.length === 0,
      missing,
      buildInfo,
    });
  })());
});
