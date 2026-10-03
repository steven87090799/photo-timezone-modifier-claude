/**
 * worker.js — 背景壓縮引擎（優化版）
 *
 * 支援格式：
 *  - JPEG: MozJPEG — progressive + smoothing:0（保留細節）
 *  - PNG:  OxiPNG  — level 映射優化
 *  - WebP: libwebp — method:6（最佳壓縮效率）+ sns_strength
 *  - AVIF: libaom  — speed:4 + sharpness + subsample
 *  - HEIF: macOS ImageIO 原生 HEVC 編碼器
 *  - JXL:  libjxl  — 封存主力；quality=100 時走 lossless（像素無損）
 *
 * 額外職責：
 *  - EXIF 2.32:時區覆寫(OffsetTime*)、批次時間平移(DateTime*)
 *  - Orientation 重設:像素已於解碼時轉正,輸出 EXIF 必須改回 1
 *  - ICC Profile:JPEG APP2 原樣保留;WebP 重組為 ICCP chunk
 *  - PREVIEW_ENCODE:300×300 中央區域快速編碼(Side-by-Side 即時預覽)
 */

import { shiftExifDateString, sniffGifAnimation } from './runtime-policy.js?v=3.2.1&b=nexpress-3.2.1-g3.2.1-04361249b1d3-f4fee95b300cb982';

// The page passes its generated release/build identity in the Worker URL.
// Invalid identity fails closed instead of inventing a plausible generation.
const workerModuleUrl = new URL(import.meta.url);
const rawGeneration = workerModuleUrl.searchParams.get('v') || '';
const rawBuildId = workerModuleUrl.searchParams.get('b') || '';
const releaseToken = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const buildToken = /^[0-9A-Za-z][0-9A-Za-z.+_-]{7,159}$/;
const APP_VERSION = releaseToken.test(rawGeneration) ? rawGeneration : 'unverified';
const BUILD_ID = buildToken.test(rawBuildId) ? rawBuildId : 'unverified';

// ── WASM 模組快取 ──────────────────────────────────────────
let encoders = {};
let initDone = false;
const FORMAT_ENCODER = {
  'image/jpeg': 'jpeg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/avif': 'avif',
  'image/jxl': 'jxl',
  'image/heif': 'heif',
};

function currentCapabilities() {
  return {
    formats: Object.fromEntries(
      Object.entries(FORMAT_ENCODER).map(([format, encoder]) => [format, Boolean(encoders[encoder])])
    ),
    exif: Boolean(encoders.piexif),
  };
}

async function initEncoders() {
  try {
    const moduleSpecs = [
      { name: 'jpeg', label: 'JPEG', engine: 'MozJPEG', purpose: '漸進式 JPEG、Trellis 最佳化與高相容輸出' },
      { name: 'png', label: 'PNG', engine: 'OxiPNG', purpose: '像素無損重壓與透明通道保留' },
      { name: 'webp', label: 'WebP', engine: 'libwebp', purpose: '高效率網站圖片與 Sharp YUV 色彩轉換' },
      { name: 'avif', label: 'AVIF', engine: 'libaom-av1', purpose: 'AV1 靜態影像與 SSIM 感知品質調校' },
      { name: 'jxl', label: 'JXL', engine: 'libjxl', purpose: 'JPEG XL 有損輸出與像素無損封存' },
      { name: 'heif', label: 'HEIF', engine: 'macOS ImageIO', purpose: '原生 HEVC 編碼與 HEIF 容器輸出' },
      { name: 'piexif', label: 'EXIF', engine: 'Piexifjs', purpose: 'EXIF 2.32、時區、GPS 與拍攝時間處理' },
    ];
    const specByName = Object.fromEntries(moduleSpecs.map((spec, index) => [spec.name, { ...spec, index: index + 1, total: moduleSpecs.length }]));

    const loadEncoder = async (name, path, initFn) => {
      const spec = specByName[name];
      const startedAt = performance.now();
      try {
        self.postMessage({ type: 'INIT_PROGRESS', status: 'loading', ...spec });
        const mod = await import(path);
        if (initFn) await initFn(mod);
        encoders[name] = mod;
        self.postMessage({
          type: 'INIT_PROGRESS',
          status: 'ready',
          elapsedMs: Math.round(performance.now() - startedAt),
          ...spec,
        });
        console.log(`[SYS] ${name.toUpperCase()} encoder ready.`);
        return true;
      } catch (err) {
        console.error(`[ERR] Failed to load ${name} encoder:`, err);
        self.postMessage({
          type: 'INIT_PROGRESS',
          status: 'failed',
          elapsedMs: Math.round(performance.now() - startedAt),
          error: err?.message || String(err),
          ...spec,
        });
        return false;
      }
    };

    // 固定版本 buster:URL 穩定才能被 Service Worker / HTTP 快取命中(離線關鍵)
    const buster = `?v=${encodeURIComponent(APP_VERSION)}&b=${encodeURIComponent(BUILD_ID)}`;

    await loadEncoder('jpeg', `./vendor/jpeg.js${buster}`);
    await loadEncoder('png', `./vendor/png.js${buster}`);
    await loadEncoder('webp', `./vendor/webp.js${buster}`);
    await loadEncoder('avif', `./vendor/avif.js${buster}`);
    await loadEncoder('jxl', `./vendor/jxl.js${buster}`);

    const nativeSpec = specByName.heif;
    self.postMessage({ type: 'INIT_PROGRESS', status: 'loading', ...nativeSpec });
    try {
      const response = await fetch(new URL('./native/health', workerModuleUrl), { cache: 'no-store' });
      if (!response.ok || !(await response.json()).heif) throw new Error('macOS ImageIO HEIF 不可用');
      encoders.heif = { native: true };
      self.postMessage({ type: 'INIT_PROGRESS', status: 'ready', ...nativeSpec });
    } catch (error) {
      self.postMessage({ type: 'INIT_PROGRESS', status: 'failed', error: error.message, ...nativeSpec });
    }

    // EXIF parser loads last (lightweight, no WASM)
    const piexifLoaded = await loadEncoder('piexif', `./vendor/piexif.js${buster}`, (mod) => {
      const pMod = mod.default || mod;
      // Patch old piexif version to support modern EXIF 2.31 Timezone tags
      if (pMod && pMod.TAGS && pMod.TAGS.Exif) {
        pMod.TAGS.Exif[36880] = { name: "OffsetTime", type: "Ascii" };
        pMod.TAGS.Exif[36881] = { name: "OffsetTimeOriginal", type: "Ascii" };
        pMod.TAGS.Exif[36882] = { name: "OffsetTimeDigitized", type: "Ascii" };
      }
    });

    // Fix ESM namespace for piexif (it exports everything on default)
    if (piexifLoaded && encoders.piexif) {
      encoders.piexif = encoders.piexif.default || encoders.piexif;
    } else {
      encoders.piexif = null;
    }

    initDone = true;
    self.postMessage({
      type: 'READY',
      generation: APP_VERSION,
      buildId: BUILD_ID,
      capabilities: currentCapabilities(),
    });
  } catch (err) {
    console.error('Fatal initialization error:', err);
    self.postMessage({ type: 'INIT_ERROR', error: err.message });
  }
}

initEncoders();

async function nativeHeifDecode(blob) {
  const response = await fetch(new URL('./native/heif/decode', workerModuleUrl), {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream' },
    body: blob,
  });
  if (!response.ok) throw new Error((await response.text()).slice(0, 300));
  return response.blob();
}

async function nativeHeifEncode(imageData, quality) {
  const rgba = new Uint8Array(
    imageData.data.buffer, imageData.data.byteOffset, imageData.data.byteLength
  );
  const response = await fetch(new URL('./native/heif/encode', workerModuleUrl), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/octet-stream',
      'X-Image-Width': String(imageData.width),
      'X-Image-Height': String(imageData.height),
      'X-Image-Quality': String(quality),
    },
    body: rgba,
  });
  if (!response.ok) throw new Error((await response.text()).slice(0, 300));
  return response.arrayBuffer();
}

self.onmessage = async (e) => {
  const { type, id, file, format, quality, modifyTz, tzOffset, timeShiftMinutes, jxlRecovery, requestToken } = e.data;

  if (type === 'COMPRESS') {
    if (!initDone) {
      self.postMessage({ type: 'TASK_ERROR', id, error: 'WASM 引擎尚未就緒，請稍後再試' });
      return;
    }
    const requiredEncoder = FORMAT_ENCODER[format];
    if (!requiredEncoder || !encoders[requiredEncoder]) {
      self.postMessage({ type: 'TASK_ERROR', id, error: `所選格式目前不可用: ${format || 'unknown'}` });
      return;
    }
    await processTask({
      id, file, format, quality, modifyTz, tzOffset, timeShiftMinutes, jxlRecovery,
    });
  } else if (type === 'PREVIEW_ENCODE') {
    await processPreview(e.data);
  } else if (type === 'EXIF_READ_ONLY') {
    // EXIF reading doesn't need WASM encoders — allowed even before initDone
    try {
      const buf = await file.arrayBuffer();
      const view = new Uint8Array(buf);
      const appMarkers = extractAppMarkersFromView(view);
      const dims = sniffImageDimensions(view);
      const animated = sniffAnimation(view); // 動畫來源警示:壓縮輸出只會保留第一幀
      const dimsMeta = (dims || animated)
        ? { width: dims?.width ?? null, height: dims?.height ?? null, animated }
        : null;
      const exifMarker = appMarkers.find(am => am.marker === 0xE1 && am.data.length >= 6 &&
                                         am.data[0]===0x45 && am.data[1]===0x78 &&
                                         am.data[2]===0x69 && am.data[3]===0x66);
      if (exifMarker) {
        await parseExifMeta(id, exifMarker.data, false, null, 0, requestToken, dimsMeta);
      } else {
        self.postMessage({ type: 'EXIF_META', id, meta: dimsMeta ? { camera: null, timezone: null, gps: null, dateTime: null, bytes: 0, ...dimsMeta } : null, requestToken });
      }
    } catch (err) {
      console.warn('EXIF read only failed:', err);
      self.postMessage({ type: 'EXIF_META', id, meta: null, requestToken });
    }
  }
};

// ── 主壓縮邏輯（優化參數版）────────────────────────────────
async function processTask({ id, file, format, quality, modifyTz, tzOffset, timeShiftMinutes, jxlRecovery = false }) {
  try {
    self.postMessage({ type: 'TASK_START', id, status: 'INITIALIZING...', pct: 10 });

    let sourceForBitmap = file;

    if (file.type === 'image/heic' || file.type === 'image/heif' ||
        file.name.toLowerCase().endsWith('.heic') || file.name.toLowerCase().endsWith('.heif')) {
      try {
        self.postMessage({ type: 'TASK_PROGRESS', id, status: 'HEIC DECODING...', pct: 15 });
        sourceForBitmap = await nativeHeifDecode(file);
      } catch (heicErr) {
        throw new Error(`HEIC 解碼失敗: ${heicErr.message}`);
      }
    }

    // 2. Extract ALL APP markers (Exif, ICC, XMP) from the ORIGINAL file
    let appMarkers = await extractAppMarkers(file);
    let exifPayloadForWebP = null;
    let appliedTz = null;
    let appliedShift = null;

    if (appMarkers && appMarkers.length > 0) {
      try {
        const exifMarker = appMarkers.find(am => am.marker === 0xE1 && am.data.length >= 6 &&
                                           am.data[0]===0x45 && am.data[1]===0x78 &&
                                           am.data[2]===0x69 && am.data[3]===0x66);
        let exifPayload = exifMarker ? exifMarker.data : null;

        if (exifPayload) {
          // Compression is a separate post-editing step. Even if an older
          // controller sends timezone controls, the worker never applies them.
          const { currentTz, newPayload } = await parseExifMeta(id, exifPayload, false, null, 0);
          appliedTz = currentTz;
          if (newPayload) {
            exifMarker.data = newPayload; // Update the marker in the array in-place!
            exifPayloadForWebP = newPayload;
          } else {
            exifPayloadForWebP = exifPayload;
          }
          // ── Orientation 重設(關鍵正確性修復)──────────────────
          // createImageBitmap 預設 imageOrientation:'from-image'(WHATWG spec),
          // 解碼出的像素「已經轉正」。若把原始 EXIF 的 Orientation(3/6/8)原樣
          // 注回輸出檔,檢視器會再旋轉一次 → 雙重旋轉。
          // 這裡用 in-place 二進位 patch(TIFF 6.0:SHORT 值 ≤4 bytes 內嵌於
          // entry value 欄位),不經 piexif 重序列化,MakerNote offsets 不受影響。
          // exifPayloadForWebP 與 exifMarker.data 在此處恆為同一個 Uint8Array
          // (指向同一塊 buffer),patch 一次即對兩者同時生效,故只需呼叫一次。
          resetExifOrientationInPayload(exifMarker.data);
        } else {
          self.postMessage({ type: 'EXIF_META', id, meta: { camera: null, timezone: null, gps: null, dateTime: null, bytes: 0 } });
        }
      } catch (e) {
        console.warn('EXIF parsing/mod failed:', e);
        self.postMessage({ type: 'EXIF_META', id, meta: { camera: null, timezone: null, gps: null, dateTime: null, bytes: 0 } });
      }
    } else {
      self.postMessage({ type: 'EXIF_META', id, meta: null });
    }

    // 3. 在背景執行緒將 File 解碼為 ImageData
    self.postMessage({ type: 'TASK_PROGRESS', id, status: 'DECODING...', pct: 30 });
    const imageData = await fileToImageData(sourceForBitmap);
    if (!imageData || !imageData.data) {
      throw new Error(`無法從檔案取得影像數據 (ImageData 為空)`);
    }

    let buffer;
    const q = quality / 100; // 轉換到 0~1

    switch (format) {
      case 'image/jpeg': {
        if (!encoders.jpeg) throw new Error('JPEG 編碼器未載入');
        self.postMessage({ type: 'TASK_PROGRESS', id, status: 'ENCODING...', pct: 60 });
        // MozJPEG 優化參數（vendored @jsquash/jpeg 預設已含 optimize_coding:true —
        // Huffman table 最佳化本來就開啟,無需重複指定):
        //   quality: 使用者設定值 (建議 80-85 最佳性價比)
        //   progressive: true — 漸進式 JPEG,檔案更小且載入體驗更好
        //   smoothing: 0 — 不做平滑處理,保留影像細節
        //   trellis_opt_zero: true — EOB trellis 最佳化,幾乎零成本再省 ~0.5-1%
        //   trellis_multipass: true — 跨 progressive scans 的 trellis,配合 progressive 模式
        //   quality >= 90 時關閉色度子採樣(4:4:4):高品質檔位保住紅字/
        //   飽和色邊緣,體積增幅僅發生在使用者明確要高品質的檔位。
        buffer = await encoders.jpeg.encode(imageData, {
          quality: quality,
          progressive: true,
          smoothing: 0,
          trellis_opt_zero: true,
          trellis_multipass: true,
          ...(quality >= 90 ? { auto_subsample: false, chroma_subsample: 1 } : {}),
        });
        break;
      }
      case 'image/png': {
        if (!encoders.png) throw new Error('PNG 編碼器未載入');
        self.postMessage({ type: 'TASK_PROGRESS', id, status: 'ENCODING...', pct: 60 });
        // OxiPNG 優化參數：
        //   level: 映射 quality 到 0~6（6 = 最小檔案但最慢）
        //   無損格式，level 只影響壓縮效率不影響品質
        const level = Math.min(Math.round(q * 6), 6);
        buffer = await encoders.png.encode(imageData, {
          level,
        });
        break;
      }
      case 'image/webp': {
        if (!encoders.webp) throw new Error('WebP 編碼器未載入');
        self.postMessage({ type: 'TASK_PROGRESS', id, status: 'ENCODING...', pct: 60 });
        // libwebp 優化參數：
        //   quality: 使用者設定值 (建議 78-82 最佳性價比)
        //   method: 6 — 最慢但壓縮率最高的演算法 (0=最快, 6=最佳)
        //   sns_strength: 50 — 空間噪聲整形，在細節區域保留更多資訊
        //   use_sharp_yuv: 1 — Sharp RGB→YUV 轉換,大幅減少飽和色邊緣的
        //   色度滲色(chroma bleeding),同一體積下畫質更好,僅編碼稍慢。
        buffer = await encoders.webp.encode(imageData, {
          quality: quality,
          method: 6,
          sns_strength: 50,
          use_sharp_yuv: 1,
        });
        break;
      }
      case 'image/avif': {
        if (!encoders.avif) throw new Error('AVIF 編碼器未載入');
        self.postMessage({ type: 'TASK_PROGRESS', id, status: 'ENCODING...', pct: 60 });
        // libaom-av1 優化參數：
        //   cqLevel: quality 到 CQ 等級的映射（0=最高品質, 63=最低）
        //   speed: 4   — 比預設更慢但壓縮率更好 (1=最慢最好, 10=最快)
        //   sharpness: 1 — 輕微銳利度補償，抵消壓縮造成的模糊
        //   subsample: 1 — YUV420 色度子採樣，大幅縮小檔案體積
        //   tune: 2 (SSIM) — 以感知品質為目標,同 cq 下主觀畫質優於預設 PSNR
        //   chromaDeltaQ: true — 色度平面獨立 QP 調整,膚色/漸層更乾淨
        //   subsample: quality >= 90 時改 4:4:4,高品質檔位不犧牲色度解析
        const cqLevel = Math.round((1 - q) * 63);
        buffer = await encoders.avif.encode(imageData, {
          cqLevel,
          speed: 4,
          sharpness: 1,
          subsample: quality >= 90 ? 3 : 1,
          chromaDeltaQ: true,
          tune: 2,
        });
        break;
      }
      case 'image/jxl': {
        if (!encoders.jxl) throw new Error('JXL 編碼器未載入');
        const isNearLosslessRecovery = Boolean(jxlRecovery);
        self.postMessage({
          type: 'TASK_PROGRESS',
          id,
          status: isNearLosslessRecovery ? 'RECOVERY: JXL Q99...' : 'ENCODING...',
          pct: 60,
        });
        // libjxl (via @jsquash/jxl):
        //   quality >= 100 → lossless:true（像素無損）
        //   大圖的無損模式可能讓 WASM 中止。中止後 Emscripten instance 不可重用，
        //   因此由 main.js 回收整個 Worker，再以 quality 99（近無損）重送。
        //   recovery 必須從 effort 1 開始，不能先讓已知耗記憶體的 effort 再次中止。
        const jxlLossless = quality >= 100 && !isNearLosslessRecovery;
        const effectiveQuality = isNearLosslessRecovery ? 99 : quality;
        const pixels = imageData.width * imageData.height;
        const startEffort = isNearLosslessRecovery ? 1
                          : pixels > 20_000_000 ? (jxlLossless ? 1 : 3)
                          : pixels > 12_000_000 ? (jxlLossless ? 3 : 5)
                          : 7;
        const jxlOpts = (effort) => jxlLossless
          ? { lossless: true, effort }
          : { quality: effectiveQuality, effort, lossless: false };
        try {
          buffer = await encoders.jxl.encode(imageData, jxlOpts(startEffort));
        } catch (jxlErr) {
          // quality 100 是嚴格像素無損承諾。遇到任何底層 JXL 失敗時，絕不在
          // 已經 Aborted 的 instance 上重試；交由主執行緒換乾淨 Worker，並明示
          // 地改用 quality 99。這不是隱性降級，TASK_DONE 會附上 jxlRecovery 標記。
          if (jxlLossless) {
            self.postMessage({
              type: 'TASK_JXL_NEAR_LOSSLESS_RETRY',
              id,
              error: jxlErr?.message || String(jxlErr),
              requestedQuality: quality,
              effectiveQuality: 99,
            });
            return;
          }
          // 退階重試一次。WASM OOM 的錯誤訊息形態不可靠
          // ('Aborted()'、'RuntimeError: unreachable'、裸數字 C++ exception 都可能),
          // 無法安全地只挑 OOM 重試,故一律重試;確定性錯誤只多付一次編碼成本。
          // 無損比有損吃記憶體,退階降到已驗證安全的低檔位。
          const fallbackEffort = Math.max(1, startEffort - (jxlLossless ? 4 : 2));
          if (fallbackEffort >= startEffort) throw jxlErr;  // 已在最低檔,重試必然同樣失敗
          self.postMessage({ type: 'TASK_PROGRESS', id, status: `RETRY (effort ${fallbackEffort})...`, pct: 65 });
          buffer = await encoders.jxl.encode(imageData, jxlOpts(fallbackEffort));
        }
        break;
      }
      case 'image/heif': {
        if (!encoders.heif) throw new Error('HEIF 編碼器未載入');
        self.postMessage({ type: 'TASK_PROGRESS', id, status: 'ENCODING...', pct: 60 });
        buffer = await nativeHeifEncode(imageData, quality);
        break;
      }
      default:
        throw new Error(`不支援的格式：${format}`);
    } // end switch

    if (!buffer) throw new Error('編碼失敗：輸出的緩衝區為空');

    let finalBuffer = buffer;
    const jpegSource = file.type === 'image/jpeg' || /\.jpe?g$/i.test(file.name);
    let metadataStatus = jpegSource
      ? '來源 JPEG 中繼資料可讀；輸出格式尚未核對'
      : '來源非 JPEG；EXIF／ICC／XMP 無法完整提取，請核對輸出';
    self.postMessage({ type: 'TASK_PROGRESS', id, status: 'DONE', pct: 100 });
    if (appMarkers && appMarkers.length > 0) {
      try {
        if (format === 'image/jpeg') {
          finalBuffer = injectAllAppMarkersToJpeg(buffer, appMarkers);
          metadataStatus = jpegSource
            ? '已複製來源 JPEG 的 EXIF／ICC／XMP APP 區段（方向欄位依轉正像素更新）'
            : '已複製可提取的中繼資料；來源非 JPEG，無法確認全部保留';
        } else if (format === 'image/webp') {
          // RFC 9649: VP8X, ICCP, image, EXIF, XMP.
          const iccProfile = extractIccProfile(appMarkers);
          const xmpPacket = extractXMPPacket(appMarkers);
          finalBuffer = injectMetadataToWebP(buffer, exifPayloadForWebP, iccProfile, xmpPacket, imageData.width, imageData.height);
          metadataStatus = jpegSource
            ? '已複製來源 JPEG 的 EXIF／ICC／XMP 到 WebP 容器（方向欄位依轉正像素更新）'
            : '已複製可提取的中繼資料；來源非 JPEG，無法確認全部保留';
        }
        // JXL / AVIF / HEIF / PNG:編碼器不接受 metadata 注入(容器層 API 未暴露)—
        // 已知限制,於 README 與 UI 明確標示,不做「看似成功實則丟失」的假動作。
      } catch (exifErr) {
        throw new Error(`中繼資料無法安全保留，未輸出此檔：${exifErr.message}`);
      }
    }
    if (!['image/jpeg', 'image/webp'].includes(format)) {
      metadataStatus = '此輸出格式目前不保留來源 EXIF／ICC／XMP（包括時區與 GPS）';
    }

    // 4. 使用 Transferable 零複製傳回
    self.postMessage(
      {
        type: 'TASK_DONE', id, buffer: finalBuffer, format,
        timezone: appliedTz, timeShift: null, metadataStatus,
        width: imageData.width, height: imageData.height,
        jxlRecovery: format === 'image/jxl' && Boolean(jxlRecovery),
        effectiveQuality: format === 'image/jxl' && jxlRecovery ? 99 : quality,
      },
      [finalBuffer]
    );
  } catch (err) {
    console.error(`Task ${id} failed:`, err);
    self.postMessage({ type: 'TASK_ERROR', id, error: err.message || '發生未知錯誤' });
  }
}

// ══════════════════════════════════════════════════════════
// ── EXIF 與圖片處理工具 (從 main.js 移入) ────────────────
// ══════════════════════════════════════════════════════════

// Hoist constant array out of hot loop — avoids re-allocation per IFD entry
const FORMAT_SIZES = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8];

/**
 * bytes → binary string 的 1:1 轉換(piexif 專用)。
 * 【關鍵修復】不可用 TextDecoder('latin1'):WHATWG 編碼標準把 "latin1" 對映到
 * windows-1252,bytes 0x80–0x9F 會解碼成 €、…、™ 等(code point > 255),
 * piexif 用 charCodeAt 讀值時 TIFF 偏移量全部錯亂 → 解析失敗或悄悄損毀。
 * String.fromCharCode(byte) 保證 1:1 對映(0x00–0xFF → U+0000–U+00FF)。
 */
function bytesToBinaryString(u8) {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, u8.subarray(i, Math.min(i + 0x8000, u8.length)));
  }
  return s;
}

async function parseExifMeta(id, exifPayload, modifyTz = false, tzOffset = null, timeShiftMinutes = 0, requestToken = null, dims = null) {
  let cameraMake = null, cameraModel = null, software = null;
  let dateTime = null, currentTz = null;
  let gpsLat = null, gpsLon = null;

  try {
    if (exifPayload && exifPayload.length >= 14) {
      const view = new DataView(exifPayload.buffer, exifPayload.byteOffset, exifPayload.byteLength);
      // 'Exif\0\0' magic
      if (view.getUint32(0) === 0x45786966) {
        const tiffOffset = 6;
        const littleEndian = view.getUint16(tiffOffset) === 0x4949; // 'II'
        if (view.getUint16(tiffOffset + 2, littleEndian) === 0x002A) {
          const ifd0Offset = view.getUint32(tiffOffset + 4, littleEndian);
          const textDecoder = new TextDecoder('latin1');

          function sanitizeExifString(str) {
            if (!str) return null;
            const cleaned = str.replace(/\0+$/g, '').replace(/\s+/g, ' ').trim();
            if (!cleaned) return null;
            const printableChars = cleaned.match(/[\x20-\x7E\u00A0-\u00FF]/g) || [];
            const printableRatio = printableChars.length / cleaned.length;
            if (printableRatio < 0.85) return null;
            return cleaned;
          }

          function readString(offset, length) {
            if (length <= 0 || offset < 0 || offset >= view.byteLength) return null;
            const end = Math.min(offset + length, view.byteLength);
            const raw = textDecoder.decode(new Uint8Array(view.buffer, view.byteOffset + offset, end - offset));
            return sanitizeExifString(raw);
          }

          function readRational(offset) {
            if (offset + 8 > view.byteLength) return 0;
            const num = view.getUint32(offset, littleEndian);
            const den = view.getUint32(offset + 4, littleEndian);
            return den === 0 ? 0 : num / den;
          }

          const gpsCtx = {};

          function parseIFD(offset, type) {
            if (offset + 2 > view.byteLength) return;
            const numEntries = view.getUint16(offset, littleEndian);
            let ptr = offset + 2;
            for (let i = 0; i < numEntries; i++) {
              if (ptr + 12 > view.byteLength) break;
              const tag = view.getUint16(ptr, littleEndian);
              const dataFormat = view.getUint16(ptr + 2, littleEndian);
              const numComponents = view.getUint32(ptr + 4, littleEndian);
              const dataValue = ptr + 8;

              const formatSizes = FORMAT_SIZES;
              const dataSize = numComponents * (formatSizes[dataFormat] || 0);
              if (!dataSize) {
                ptr += 12;
                continue;
              }
              let dataOffset = dataValue;
              if (dataSize > 4) {
                dataOffset = tiffOffset + view.getUint32(dataValue, littleEndian);
              }

              if (dataOffset >= 0 && dataOffset + dataSize <= view.byteLength) {
                if (type === 'IFD0') {
                  if (tag === 0x010F) cameraMake = readString(dataOffset, numComponents);
                  if (tag === 0x0110) cameraModel = readString(dataOffset, numComponents);
                  if (tag === 0x0131) software = readString(dataOffset, numComponents);
                  if (tag === 0x0132) dateTime = readString(dataOffset, numComponents);
                  if (tag === 0x8769) parseIFD(tiffOffset + view.getUint32(dataValue, littleEndian), 'ExifSubIFD');
                  if (tag === 0x8825) parseIFD(tiffOffset + view.getUint32(dataValue, littleEndian), 'GPS');
                } else if (type === 'ExifSubIFD') {
                  if (tag === 0x9003 && !dateTime) dateTime = readString(dataOffset, numComponents);
                  if (tag === 0x9004 && !dateTime) dateTime = readString(dataOffset, numComponents);
                  if (tag === 0x9010) currentTz = readString(dataOffset, numComponents);
                  if (tag === 0x9011 && !currentTz) currentTz = readString(dataOffset, numComponents);
                  if (tag === 0x9012 && !currentTz) currentTz = readString(dataOffset, numComponents);
                } else if (type === 'GPS') {
                  if (tag === 0x0001) gpsCtx.latRef = readString(dataOffset, numComponents);
                  if (tag === 0x0002) gpsCtx.lat = [readRational(dataOffset), readRational(dataOffset+8), readRational(dataOffset+16)];
                  if (tag === 0x0003) gpsCtx.lonRef = readString(dataOffset, numComponents);
                  if (tag === 0x0004) gpsCtx.lon = [readRational(dataOffset), readRational(dataOffset+8), readRational(dataOffset+16)];
                }
              }
              ptr += 12;
            }
          }

          parseIFD(tiffOffset + ifd0Offset, 'IFD0');

          // Compute GPS decimals
          if (gpsCtx.lat && gpsCtx.latRef) {
            const latVal = gpsCtx.lat[0] + gpsCtx.lat[1]/60 + gpsCtx.lat[2]/3600;
            gpsLat = (gpsCtx.latRef === 'S' || gpsCtx.latRef === 's') ? -latVal : latVal;
          }
          if (gpsCtx.lon && gpsCtx.lonRef) {
            const lonVal = gpsCtx.lon[0] + gpsCtx.lon[1]/60 + gpsCtx.lon[2]/3600;
            gpsLon = (gpsCtx.lonRef === 'W' || gpsCtx.lonRef === 'w') ? -lonVal : lonVal;
          }

          // Clean up camera formatting
          if (cameraMake && cameraModel && cameraModel.toUpperCase().startsWith(cameraMake.toUpperCase())) {
            cameraMake = null; // Prevent "SONY SONY ILCE-7M4"
          }
        }
      }
    }
  } catch (err) {
    console.warn('Native EXIF parse error:', err);
  }

  try {
    if (encoders.piexif && exifPayload?.length) {
      const binStr = bytesToBinaryString(exifPayload);
      const exifDict = encoders.piexif.load(binStr);
      const imageIfd = exifDict["0th"] || {};
      const exifIfd = exifDict["Exif"] || {};
      const gpsIfd = exifDict["GPS"] || {};

      const fallbackMake = imageIfd[271];
      const fallbackModel = imageIfd[272];
      const fallbackSoftware = imageIfd[305];
      const fallbackDateTime = imageIfd[306] || exifIfd[36867] || exifIfd[36868];
      const fallbackTz = exifIfd[36880] || exifIfd[36881] || exifIfd[36882] || imageIfd[34858];

      cameraMake = cameraMake || fallbackMake || null;
      cameraModel = cameraModel || fallbackModel || null;
      software = software || fallbackSoftware || null;
      dateTime = dateTime || fallbackDateTime || null;
      currentTz = currentTz || fallbackTz || null;

      const gpsLatRef = gpsIfd[1];
      const gpsLatVal = gpsIfd[2];
      const gpsLonRef = gpsIfd[3];
      const gpsLonVal = gpsIfd[4];
      const rationalTripletToDecimal = (parts, ref) => {
        if (!Array.isArray(parts) || parts.length < 3) return null;
        const toNum = (pair) => Array.isArray(pair) && pair.length >= 2 && pair[1] ? pair[0] / pair[1] : 0;
        const deg = toNum(parts[0]);
        const min = toNum(parts[1]);
        const sec = toNum(parts[2]);
        const value = deg + min / 60 + sec / 3600;
        if (!Number.isFinite(value)) return null;
        return ref === 'S' || ref === 'W' ? -value : value;
      };

      if (gpsLat === null && gpsLon === null && gpsLatRef && gpsLatVal && gpsLonRef && gpsLonVal) {
        const lat = rationalTripletToDecimal(gpsLatVal, gpsLatRef);
        const lon = rationalTripletToDecimal(gpsLonVal, gpsLonRef);
        if (lat !== null && lon !== null) {
          gpsLat = lat;
          gpsLon = lon;
        }
      }
    }
  } catch (err) {
    console.warn('Piexif EXIF parse fallback failed:', err);
  }

  // 優先用型號，若無型號只有品牌也顯示品牌，兩者皆無則嘗試 Software 欄位
  const cameraStr = cameraModel
    ? `${cameraMake || ''} ${cameraModel}`.trim()
    : cameraMake
      ? cameraMake.trim()
      : software
        ? `via ${software.split(/[\s/]/)[0]}`  // e.g. "via Lightroom"
        : null;

  self.postMessage({
    type: 'EXIF_META', id,
    meta: {
      camera: cameraStr,
      software,
      timezone: currentTz,
      gps: (gpsLat !== null && gpsLon !== null) ? `${gpsLat.toFixed(6)}, ${gpsLon.toFixed(6)}` : null,
      dateTime,
      bytes: exifPayload.length,
      width: dims?.width ?? null,
      height: dims?.height ?? null,
      animated: dims?.animated ?? false,
    },
    requestToken,
  });

  let newPayload = null;
  let modifiedTz = null;
  let shiftedMinutes = null;

  const wantShift = Number.isFinite(timeShiftMinutes) && timeShiftMinutes !== 0;
  const wantTz = modifyTz && tzOffset;

  if (wantTz || wantShift) {
    try {
      if (!encoders.piexif) throw new Error('piexif not loaded');
      const binStr = bytesToBinaryString(exifPayload); // Already starts with "Exif\0\0"

      const pMod = encoders.piexif;
      const exifDict = pMod.load(binStr);
      if (!exifDict["Exif"]) exifDict["Exif"] = {};

      if (wantTz) {
        // EXIF 2.32:OffsetTime* 為 "±HH:MM" 7-byte Ascii(含 NUL,piexif 自動補)
        exifDict["Exif"][36880] = tzOffset; // OffsetTime        ↔ DateTime (0x0132)
        exifDict["Exif"][36881] = tzOffset; // OffsetTimeOriginal ↔ DateTimeOriginal (0x9003)
        exifDict["Exif"][36882] = tzOffset; // OffsetTimeDigitized ↔ DateTimeDigitized (0x9004)
      }

      if (wantShift) {
        // 批次時間平移(= exiftool -AllDates+=N):只動三個 wall-clock 欄位 + 縮圖 IFD。
        // 不動 GPS(GPS 是 UTC 原子鐘,相機時鐘錯誤時 GPS 本來就是對的)、
        // 不動 SubSecTime*(整秒平移不影響次秒)、
        // 不動 0x882A TimeZoneOffset(piexif 將其定型為無號 Long,負值會損毀)。
        const shiftTargets = [
          ["0th", 306],    // DateTime / ModifyDate
          ["Exif", 36867], // DateTimeOriginal
          ["Exif", 36868], // DateTimeDigitized
          ["1st", 306],    // 縮圖 IFD 的 DateTime(如存在)
        ];
        let shiftedAny = false;
        for (const [ifd, tag] of shiftTargets) {
          const cur = exifDict[ifd]?.[tag];
          if (typeof cur !== 'string') continue;
          const shifted = shiftExifDateString(cur, timeShiftMinutes);
          if (shifted) {
            exifDict[ifd][tag] = shifted;
            shiftedAny = true;
          }
        }
        if (shiftedAny) shiftedMinutes = timeShiftMinutes;
      }

      // piexif dump() 沒有總長度守衛(僅縮圖 >64KB 會 throw)。
      // APP1 segment 長度欄是 16-bit:payload 上限 65533 bytes(含 "Exif\0\0")。
      // 超限時先剝除縮圖再試一次;仍超限就放棄修改、保留原始 payload(loud, not corrupt)。
      let newDump = pMod.dump(exifDict);
      if (newDump.length > 65533) {
        console.warn(`EXIF payload ${newDump.length}B exceeds APP1 cap — stripping thumbnail and retrying`);
        exifDict["thumbnail"] = null;
        exifDict["1st"] = {};
        newDump = pMod.dump(exifDict);
        if (newDump.length > 65533) {
          throw new Error(`EXIF payload still ${newDump.length}B > 65533B after thumbnail strip`);
        }
      }
      newPayload = new Uint8Array(newDump.length);
      for (let i = 0; i < newDump.length; i++) newPayload[i] = newDump.charCodeAt(i);
      if (wantTz) modifiedTz = tzOffset;
    } catch (e) {
      console.error('Piexif EXIF rewrite failed:', e);
      newPayload = null;
      shiftedMinutes = null;
      if (wantTz) modifiedTz = `ERR: ${e.message}`; // Propagate error to UI for debugging
    }
  }

  return { currentTz, newPayload, modifiedTz, shiftedMinutes };
}

/**
 * 平移 EXIF 日期字串(嚴格 EXIF 2.32 格式 "YYYY:MM:DD HH:MM:SS",19 字元)。
 * 使用 Date.UTC epoch 運算:跨午夜/月/年與閏年翻轉全部正確,
 * 且不受宿主時區與 DST 影響(new Date(y,m,d) 會被本地時區污染,不可用)。
 * 格式不符(空白填充/損毀)時回傳 null,呼叫端保留原值不動。
 */
/**
 * Orientation 重設為 1(in-place 二進位 patch,不重序列化)。
 * TIFF 6.0:值 ≤4 bytes 直接內嵌於 IFD entry 的 value 欄位(左對齊),
 * 所以 SHORT(type 3, count 1)只需覆寫 entry+8 起的 2 bytes,
 * 任何 offset / MakerNote 都不會移動。同時支援 II/MM 兩種位元組序。
 */
function resetExifOrientationInPayload(payload) {
  try {
    if (!payload || payload.length < 16) return false;
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    if (view.getUint32(0) !== 0x45786966) return false; // 'Exif'
    const tiff = 6;
    const bom = view.getUint16(tiff);
    const le = bom === 0x4949; // 'II'
    if (!le && bom !== 0x4D4D) return false; // 'MM'
    if (view.getUint16(tiff + 2, le) !== 0x002A) return false; // TIFF magic 42
    const ifd0 = tiff + view.getUint32(tiff + 4, le);
    if (ifd0 + 2 > payload.length) return false;
    const n = view.getUint16(ifd0, le);
    for (let i = 0; i < n; i++) {
      const p = ifd0 + 2 + i * 12;
      if (p + 12 > payload.length) break;
      if (view.getUint16(p, le) !== 0x0112) continue;
      const type = view.getUint16(p + 2, le);
      const count = view.getUint32(p + 4, le);
      if (count !== 1) return false;
      if (type === 3) {          // SHORT — 標準情況
        view.setUint16(p + 8, 1, le);
        return true;
      }
      if (type === 4) {          // LONG — 非標準但可安全處理
        view.setUint32(p + 8, 1, le);
        return true;
      }
      return false;              // 其他型別:不動,避免破壞
    }
    return false; // 無 Orientation tag:檢視器預設即為 1,無需處理
  } catch {
    return false;
  }
}

// ══════════════════════════════════════════════════════════

async function fileToImageData(source) {
  let bitmap = null;
  let canvas = null;
  try {
    bitmap = source instanceof ImageBitmap ? source : await createImageBitmap(source);
    canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    if (!ctx) {
      throw new Error('無法取得 OffscreenCanvas 2D 上下文');
    }
    ctx.drawImage(bitmap, 0, 0);
    return ctx.getImageData(0, 0, bitmap.width, bitmap.height);
  } catch (err) {
    throw new Error(`影像解碼失敗: ${err.message}`);
  } finally {
    if (bitmap && typeof bitmap.close === 'function') {
      bitmap.close();
    }
    if (canvas) {
      canvas.width = 1;
      canvas.height = 1;
    }
  }
}

async function extractAppMarkers(file) {
  const buf = await file.arrayBuffer();
  return extractAppMarkersFromView(new Uint8Array(buf));
}

/**
 * 嗅探影像實際像素尺寸(不解碼像素,只讀 header)。
 * 供「AI 檔案大小預估引擎」在壓縮前取得精確像素數。
 * 支援 JPEG SOF / PNG IHDR / WebP (VP8X/VP8/VP8L);其餘回傳 null(呼叫端降級)。
 */
function sniffImageDimensions(view) {
  try {
    // JPEG:走訪 marker 找 SOFn(C0-CF,排除 C4/C8/CC)
    if (view.length > 4 && view[0] === 0xFF && view[1] === 0xD8) {
      let offset = 2;
      while (offset + 9 < view.length) {
        if (view[offset] !== 0xFF) break;
        const marker = view[offset + 1];
        if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) { offset += 2; continue; }
        const segLen = (view[offset + 2] << 8) | view[offset + 3];
        if (segLen < 2 || offset + 2 + segLen > view.length) break;
        if (marker >= 0xC0 && marker <= 0xCF && marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC) {
          const height = (view[offset + 5] << 8) | view[offset + 6];
          const width = (view[offset + 7] << 8) | view[offset + 8];
          if (width > 0 && height > 0) return { width, height };
          return null;
        }
        if (marker === 0xDA) break; // SOS:後面是 entropy data,不再有 SOF
        offset += 2 + segLen;
      }
      return null;
    }
    // GIF:Logical Screen Descriptor(bytes 6-9,little-endian)
    if (view.length > 10 && view[0] === 0x47 && view[1] === 0x49 && view[2] === 0x46 && view[3] === 0x38) {
      const width = view[6] | (view[7] << 8);
      const height = view[8] | (view[9] << 8);
      if (width > 0 && height > 0) return { width, height };
      return null;
    }
    // PNG:8-byte signature + IHDR(固定於 offset 16/20)
    if (view.length > 24 && view[0] === 0x89 && view[1] === 0x50 && view[2] === 0x4E && view[3] === 0x47) {
      const width = (view[16] << 24 | view[17] << 16 | view[18] << 8 | view[19]) >>> 0;
      const height = (view[20] << 24 | view[21] << 16 | view[22] << 8 | view[23]) >>> 0;
      if (width > 0 && height > 0 && width < 0x40000000 && height < 0x40000000) return { width, height };
      return null;
    }
    // WebP:RIFF....WEBP + 第一個 chunk
    if (view.length > 30 &&
        view[0] === 0x52 && view[1] === 0x49 && view[2] === 0x46 && view[3] === 0x46 &&
        view[8] === 0x57 && view[9] === 0x45 && view[10] === 0x42 && view[11] === 0x50) {
      const tag = String.fromCharCode(view[12], view[13], view[14], view[15]);
      if (tag === 'VP8X') {
        const width = 1 + (view[24] | (view[25] << 8) | (view[26] << 16));
        const height = 1 + (view[27] | (view[28] << 8) | (view[29] << 16));
        return { width, height };
      }
      if (tag === 'VP8 ') {
        // lossy:frame header 於 chunk payload;3-byte start code 9D 01 2A 後接 16-bit W/H
        if (view[23] === 0x9D && view[24] === 0x01 && view[25] === 0x2A) {
          const width = (view[26] | (view[27] << 8)) & 0x3FFF;
          const height = (view[28] | (view[29] << 8)) & 0x3FFF;
          if (width > 0 && height > 0) return { width, height };
        }
        return null;
      }
      if (tag === 'VP8L') {
        if (view[20] === 0x2F) {
          const b0 = view[21], b1 = view[22], b2 = view[23], b3 = view[24];
          const width = 1 + (((b1 & 0x3F) << 8) | b0);
          const height = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
          return { width, height };
        }
        return null;
      }
    }
    return null; // HEIC 等其他格式:降級(預估引擎會用 fallback)
  } catch {
    return null;
  }
}

/**
 * 動畫偵測(GIF / APNG / animated WebP)。
 * createImageBitmap 只解第一幀:動畫來源壓縮後會「靜默」變成靜態圖,
 * 在 EXIF 預讀階段偵測,讓 UI 能在執行前警告使用者。
 */
function sniffAnimation(view) {
  try {
    // GIF:animation is defined by multiple image descriptors. The optional
    // NETSCAPE loop extension is not a reliable animation signal.
    if (view.length > 13 && view[0] === 0x47 && view[1] === 0x49 && view[2] === 0x46) {
      return sniffGifAnimation(view);
    }
    // APNG:acTL chunk 出現在第一個 IDAT 之前
    if (view.length > 40 && view[0] === 0x89 && view[1] === 0x50 && view[2] === 0x4E && view[3] === 0x47) {
      let off = 8;
      while (off + 8 <= view.length) {
        const len = ((view[off] << 24) | (view[off + 1] << 16) | (view[off + 2] << 8) | view[off + 3]) >>> 0;
        const t = String.fromCharCode(view[off + 4], view[off + 5], view[off + 6], view[off + 7]);
        if (t === 'acTL') return true;
        if (t === 'IDAT' || t === 'IEND') return false;
        off += 12 + len; // length(4) + type(4) + data(len) + crc(4)
      }
      return false;
    }
    // WebP:VP8X header 的 ANIM flag(bit 1 = 0x02)
    if (view.length > 30 &&
        view[0] === 0x52 && view[1] === 0x49 && view[2] === 0x46 && view[3] === 0x46 &&
        view[8] === 0x57 && view[9] === 0x45 && view[10] === 0x42 && view[11] === 0x50) {
      if (view[12] === 0x56 && view[13] === 0x50 && view[14] === 0x38 && view[15] === 0x58) {
        return (view[20] & 0x02) !== 0;
      }
      return false;
    }
    return false;
  } catch {
    return false;
  }
}

function extractAppMarkersFromView(view) {
  // ── JPEG Handling ──────────────────────────────────────────
  if (view.length >= 2 && view[0] === 0xFF && view[1] === 0xD8) {
    let offset = 2;
    const markers = [];
    while (offset < view.length - 4) {
      if (view[offset] !== 0xFF) break;
      const marker = view[offset + 1];
      if (marker === 0xDA) break;
      if (marker === 0x00) { offset++; continue; }
      const segLen = (view[offset + 2] << 8) | view[offset + 3];
      if (segLen < 2) break; // Invalid segment length — prevent infinite loop
      const totalLen = 2 + segLen;
      if (offset + totalLen > view.length) break; // OOB guard
      if (marker >= 0xE0 && marker <= 0xEF) { // APP0-APP15 (includes JFIF APP0)
         markers.push({ marker, data: view.slice(offset + 4, offset + totalLen) });
      }
      offset += totalLen;
    }
    return markers;
  }

  // ── HEIC Handling (ISOBMFF Box Scan) ──────────────────────
  const markers = [];
  try {
    const heifExif = extractExifMarkerFromHeif(view);
    if (heifExif) {
      markers.push({ marker: 0xE1, data: heifExif });
      return markers;
    }
  } catch (e) { console.warn('HEIC structured meta parse failed:', e); }

  try {
    for (let i = 0; i < view.length - 12; i++) {
      if (view[i]===0x45 && view[i+1]===0x78 && view[i+2]===0x69 && view[i+3]===0x66) {
        if (view[i+4]===0x00 && view[i+5]===0x00) {
          const tiffStart = i + 6;
          if ((view[tiffStart]===0x49 && view[tiffStart+1]===0x49) ||
              (view[tiffStart]===0x4D && view[tiffStart+1]===0x4D)) {
            let rawData = view.slice(i, i + Math.min(65535, view.length - i));
            try {
              const binStr = bytesToBinaryString(rawData);
              const piexifMod = encoders.piexif;
              if (!piexifMod) throw new Error('piexif not loaded yet');
              const exifObj = piexifMod.load(binStr);
              const cleanBinary = piexifMod.dump(exifObj);
              const cleaned = new Uint8Array(cleanBinary.length);
              for (let j = 0; j < cleanBinary.length; j++) cleaned[j] = cleanBinary.charCodeAt(j);
              rawData = cleaned;
            } catch (e) {
              console.warn('Exif cleaning failed, using 32KB limit:', e);
              rawData = rawData.slice(0, 32768);
            }

            markers.push({ marker: 0xE1, data: rawData });
            break;
          }
        }
      }
    }
  } catch (e) { console.warn('HEIC meta scan failed:', e); }

  return markers;
}

function extractExifMarkerFromHeif(view) {
  const readAscii = (offset, len) => {
    if (offset < 0 || offset + len > view.length) return '';
    let out = '';
    for (let i = 0; i < len; i++) out += String.fromCharCode(view[offset + i]);
    return out;
  };

  const readUint = (offset, bytes) => {
    if (offset < 0 || offset + bytes > view.length) return null;
    let value = 0n;
    for (let i = 0; i < bytes; i++) value = (value << 8n) | BigInt(view[offset + i]);
    return Number(value);
  };

  const parseBoxes = (start, end) => {
    const boxes = [];
    let offset = start;
    while (offset + 8 <= end && offset + 8 <= view.length) {
      const size32 = readUint(offset, 4);
      const type = readAscii(offset + 4, 4);
      if (!size32 || !type) break;
      let headerSize = 8;
      let boxSize = size32;
      if (size32 === 1) {
        const largesize = readUint(offset + 8, 8);
        if (!largesize) break;
        boxSize = largesize;
        headerSize = 16;
      } else if (size32 === 0) {
        boxSize = end - offset;
      }
      if (boxSize < headerSize || offset + boxSize > end || offset + boxSize > view.length) break;
      boxes.push({ type, start: offset, size: boxSize, headerSize, contentStart: offset + headerSize, end: offset + boxSize });
      offset += boxSize;
    }
    return boxes;
  };

  const rootBoxes = parseBoxes(0, view.length);
  const metaBox = rootBoxes.find(box => box.type === 'meta');
  if (!metaBox || metaBox.contentStart + 4 > metaBox.end) return null;

  const metaChildren = parseBoxes(metaBox.contentStart + 4, metaBox.end);
  const iinfBox = metaChildren.find(box => box.type === 'iinf');
  const ilocBox = metaChildren.find(box => box.type === 'iloc');
  const idatBox = metaChildren.find(box => box.type === 'idat');
  if (!iinfBox || !ilocBox) return null;

  const itemTypes = new Map();
  const iinfVersion = view[iinfBox.contentStart];
  let iinfOffset = iinfBox.contentStart + 4;
  const entryCount = iinfVersion === 0 ? readUint(iinfOffset, 2) : readUint(iinfOffset, 4);
  iinfOffset += iinfVersion === 0 ? 2 : 4;
  if (!entryCount) return null;

  const infeBoxes = parseBoxes(iinfOffset, iinfBox.end);
  for (const box of infeBoxes) {
    if (box.type !== 'infe') continue;
    const version = view[box.contentStart];
    let ptr = box.contentStart + 4;
    let itemId = null;
    let itemType = null;
    if (version >= 2) {
      itemId = version === 2 ? readUint(ptr, 2) : readUint(ptr, 4);
      ptr += version === 2 ? 2 : 4;
      ptr += 2; // item_protection_index
      itemType = readAscii(ptr, 4);
    }
    if (itemId !== null && itemType) itemTypes.set(itemId, itemType);
  }

  const ilocVersion = view[ilocBox.contentStart];
  const sizeByte1 = view[ilocBox.contentStart + 4];
  const sizeByte2 = view[ilocBox.contentStart + 5];
  const offsetSize = sizeByte1 >> 4;
  const lengthSize = sizeByte1 & 0x0f;
  const baseOffsetSize = sizeByte2 >> 4;
  const indexSize = ilocVersion === 1 || ilocVersion === 2 ? (sizeByte2 & 0x0f) : 0;
  let ptr = ilocBox.contentStart + 6;
  const itemCount = ilocVersion < 2 ? readUint(ptr, 2) : readUint(ptr, 4);
  ptr += ilocVersion < 2 ? 2 : 4;
  if (!itemCount) return null;

  let exifItem = null;
  for (let i = 0; i < itemCount; i++) {
    const itemId = ilocVersion < 2 ? readUint(ptr, 2) : readUint(ptr, 4);
    ptr += ilocVersion < 2 ? 2 : 4;
    let constructionMethod = 0;
    if (ilocVersion === 1 || ilocVersion === 2) {
      constructionMethod = readUint(ptr, 2) & 0x000f;
      ptr += 2;
    }
    ptr += 2; // data_reference_index
    const baseOffset = baseOffsetSize > 0 ? readUint(ptr, baseOffsetSize) : 0;
    ptr += baseOffsetSize;
    const extentCount = readUint(ptr, 2);
    ptr += 2;

    const extents = [];
    for (let j = 0; j < extentCount; j++) {
      if ((ilocVersion === 1 || ilocVersion === 2) && indexSize > 0) ptr += indexSize;
      const extentOffset = offsetSize > 0 ? readUint(ptr, offsetSize) : 0;
      ptr += offsetSize;
      const extentLength = lengthSize > 0 ? readUint(ptr, lengthSize) : 0;
      ptr += lengthSize;
      extents.push({ extentOffset, extentLength });
    }

    if (itemTypes.get(itemId) === 'Exif') {
      exifItem = { constructionMethod, baseOffset, extents };
      break;
    }
  }

  if (!exifItem || !exifItem.extents.length) return null;

  const chunks = [];
  for (const extent of exifItem.extents) {
    const start = (exifItem.constructionMethod === 1 && idatBox)
      ? idatBox.contentStart + exifItem.baseOffset + extent.extentOffset
      : exifItem.baseOffset + extent.extentOffset;
    const end = start + extent.extentLength;
    if (start < 0 || end > view.length || end <= start) continue;
    chunks.push(view.slice(start, end));
  }
  if (!chunks.length) return null;

  const totalLength = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const payload = new Uint8Array(totalLength);
  let writeOffset = 0;
  for (const chunk of chunks) {
    payload.set(chunk, writeOffset);
    writeOffset += chunk.length;
  }
  if (payload.length < 8) return null;

  const exifOffset = readUintFromArray(payload, 0, 4);
  const tiffStartCandidates = [4 + exifOffset, exifOffset, 4];
  let tiffStart = -1;
  for (const candidate of tiffStartCandidates) {
    if (candidate >= 0 && candidate + 1 < payload.length) {
      const isTiff = (payload[candidate] === 0x49 && payload[candidate + 1] === 0x49) ||
                     (payload[candidate] === 0x4D && payload[candidate + 1] === 0x4D);
      if (isTiff) {
        tiffStart = candidate;
        break;
      }
    }
  }
  if (tiffStart === -1) return null;

  const result = new Uint8Array(6 + (payload.length - tiffStart));
  result[0] = 0x45; result[1] = 0x78; result[2] = 0x69; result[3] = 0x66; result[4] = 0x00; result[5] = 0x00;
  result.set(payload.slice(tiffStart), 6);
  return result;
}

function readUintFromArray(arr, offset, bytes) {
  if (offset < 0 || offset + bytes > arr.length) return 0;
  let value = 0;
  for (let i = 0; i < bytes; i++) value = (value * 256) + arr[offset + i];
  return value;
}

function injectAllAppMarkersToJpeg(jpegBuf, appMarkers) {
  if (!appMarkers || appMarkers.length === 0) return jpegBuf;
  const jpeg = new Uint8Array(jpegBuf);
  let cleanJpeg = removeExistingAppMarkers(jpeg);

  // JPEG marker 長度欄是 16-bit(上限 65535,扣掉長度欄自身 2 bytes = payload
  // 上限 65533)。JPEG 來源的 marker 本來就受限於這個上限(它是從真實 JPEG
  // 的長度欄讀出來的),但 HEIC/HEIF 來源的 Exif box 沒有這層限制,可能大於
  // 65533 bytes。不擋掉的話 `segLen & 0xFF` 會靜默截斷長度欄,寫出長度欄與
  // 實際資料長度不符的損毀 APP 區段。
  const safeMarkers = appMarkers.filter(mw => {
    if (mw.data.length <= 65533) return true;
    throw new Error(`JPEG APP 區段超過 65533 bytes，無法安全保留`);
  });
  if (!safeMarkers.length) return jpegBuf;

  let newAppSize = 0;
  for (const mw of safeMarkers) {
     newAppSize += 4 + mw.data.length;
  }

  const result = new Uint8Array(cleanJpeg.length + newAppSize);
  result[0] = 0xFF; result[1] = 0xD8;

  let pos = 2;
  for (const mw of safeMarkers) {
     result[pos] = 0xFF;
     result[pos+1] = mw.marker;
     const segLen = mw.data.length + 2;
     result[pos+2] = (segLen >> 8) & 0xFF;
     result[pos+3] = segLen & 0xFF;
     result.set(mw.data, pos + 4);
     pos += 4 + mw.data.length;
  }

  result.set(cleanJpeg.subarray(2), pos);
  return result.buffer;
}

function removeExistingAppMarkers(jpeg) {
  if (jpeg[0] !== 0xFF || jpeg[1] !== 0xD8) return jpeg;
  let offset = 2;
  const segments = [jpeg.subarray(0, 2)];
  while (offset < jpeg.length - 1) {
    if (jpeg[offset] !== 0xFF) break;
    const marker = jpeg[offset + 1];
    if (marker === 0xDA) { segments.push(jpeg.subarray(offset)); break; }
    if (marker === 0x00) { offset++; continue; }
    const segLen = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    if (segLen < 2) break;                              // 非法長度 — 防止錯位解析
    const totalLen = 2 + segLen;
    if (offset + totalLen > jpeg.length) break;         // OOB 防護
    // Remove APP0-APP15 (we re-inject our own set)
    if (marker >= 0xE0 && marker <= 0xEF) { offset += totalLen; continue; }
    segments.push(jpeg.subarray(offset, offset + totalLen));
    offset += totalLen;
  }
  const totalSize = segments.reduce((s, seg) => s + seg.length, 0);
  const result = new Uint8Array(totalSize);
  let pos = 0;
  for (const seg of segments) { result.set(seg, pos); pos += seg.length; }
  return result;
}

/**
 * 從 JPEG APP2 markers 抽出完整 ICC Profile。
 * 格式(ICC.1 Annex B.4):"ICC_PROFILE\0"(12B) + seq(1B, 1-based) + total(1B) + data。
 * 多段(>64KB profile)依 seq 排序後串接 — 檔案內順序不保證即 seq 順序。
 */
const ICC_HEADER = [0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00]; // "ICC_PROFILE\0"

function extractIccProfile(appMarkers) {
  if (!appMarkers?.length) return null;
  const segs = [];
  for (const am of appMarkers) {
    if (am.marker !== 0xE2 || !am.data || am.data.length <= 14) continue;
    let isIcc = true;
    for (let i = 0; i < 12; i++) {
      if (am.data[i] !== ICC_HEADER[i]) { isIcc = false; break; }
    }
    if (!isIcc) continue;
    segs.push({ seq: am.data[12], count: am.data[13], data: am.data.subarray(14) });
  }
  if (!segs.length) return null;
  segs.sort((a, b) => a.seq - b.seq);
  if (segs.some((s, i) => s.count !== segs.length || s.seq !== i + 1)) {
    throw new Error('ICC Profile 分段不完整，無法安全保留');
  }
  const total = segs.reduce((s, x) => s + x.data.length, 0);
  const out = new Uint8Array(total);
  let pos = 0;
  for (const s of segs) { out.set(s.data, pos); pos += s.data.length; }
  return out;
}

/**
 * WebP metadata 注入(EXIF + ICC)。
 * WebP Container Spec(RFC 9649)規定的 chunk 順序:
 *   VP8X → ICCP → ANIM → image data → EXIF → XMP
 * 亦即:ICCP 必須「緊接 VP8X 之後、影像資料之前」;EXIF 附於檔尾。
 * VP8X flags(MSB→LSB Rsv:2|I|L|E|X|A|R):ICC=0x20、EXIF=0x08。
 * RIFF 規則:奇數長度 chunk 補 1 個 0x00 pad byte,size 欄不含 pad。
 */
function extractXMPPacket(appMarkers) {
  const prefix = new TextEncoder().encode('http://ns.adobe.com/xap/1.0/\0');
  const extended = new TextEncoder().encode('http://ns.adobe.com/xmp/extension/\0');
  const matches = [];
  for (const marker of appMarkers || []) {
    if (marker.marker !== 0xE1) continue;
    const starts = bytes => bytes.every((byte, index) => marker.data[index] === byte);
    if (starts(extended)) throw new Error('延伸 XMP 需要重組，無法安全保留到 WebP');
    if (starts(prefix)) matches.push(marker.data.subarray(prefix.length));
  }
  if (matches.length > 1) throw new Error('來源有多個 XMP 封包，無法安全保留到 WebP');
  return matches[0] || null;
}

function injectMetadataToWebP(webpBuf, exifPayload, iccProfile, xmpPacket, width, height) {
  if (!exifPayload && !iccProfile && !xmpPacket) return webpBuf;
  const webp = new Uint8Array(webpBuf);
  if (webp.length < 20) throw new Error('WebP 輸出容器不完整');
  const riffTag = String.fromCharCode(webp[0], webp[1], webp[2], webp[3]);
  const webpTag = String.fromCharCode(webp[8], webp[9], webp[10], webp[11]);
  if (riffTag !== 'RIFF' || webpTag !== 'WEBP') throw new Error('WebP 輸出容器格式錯誤');

  const makeChunk = (fourcc, payload) => {
    const padded = payload.length % 2 === 1;
    const chunk = new Uint8Array(8 + payload.length + (padded ? 1 : 0));
    chunk[0] = fourcc.charCodeAt(0); chunk[1] = fourcc.charCodeAt(1);
    chunk[2] = fourcc.charCodeAt(2); chunk[3] = fourcc.charCodeAt(3);
    const ps = payload.length; // size 欄不含 pad byte
    chunk[4] = ps & 0xFF; chunk[5] = (ps >> 8) & 0xFF; chunk[6] = (ps >> 16) & 0xFF; chunk[7] = (ps >> 24) & 0xFF;
    chunk.set(payload, 8);
    return chunk; // pad byte 保持 0x00
  };

  // RFC 9649:EXIF chunk payload 應直接以 TIFF header(II/MM)開始。
  // "Exif\0\0" 是 JPEG APP1 專屬的識別前綴,帶進 WebP 會讓嚴格解析器讀不到
  // metadata(exiftool/Chrome 對兩種形式都容忍,但規範形式不帶前綴)。
  let exifRaw = exifPayload;
  if (exifRaw && exifRaw.length >= 6 &&
      exifRaw[0] === 0x45 && exifRaw[1] === 0x78 && exifRaw[2] === 0x69 &&
      exifRaw[3] === 0x66 && exifRaw[4] === 0x00 && exifRaw[5] === 0x00) {
    exifRaw = exifRaw.subarray(6);
  }
  const exifChunk = exifRaw && exifRaw.length ? makeChunk('EXIF', exifRaw) : null;
  const iccChunk = iccProfile ? makeChunk('ICCP', iccProfile) : null;
  const xmpChunk = xmpPacket ? makeChunk('XMP ', xmpPacket) : null;
  if (!exifChunk && !iccChunk && !xmpChunk) return webpBuf;
  const flags = (iccChunk ? 0x20 : 0) | (exifChunk ? 0x08 : 0) | (xmpChunk ? 0x04 : 0);

  const firstChunkTag = String.fromCharCode(webp[12], webp[13], webp[14], webp[15]);
  const hasVP8X = firstChunkTag === 'VP8X';

  let resultParts;
  if (hasVP8X) {
    // 既有 VP8X(18 bytes:8 header + 10 payload,始於 offset 12)
    // → flags 在 offset 20;ICCP 插入點 = offset 30(VP8X 結束處)
    const newFlags = webp[20] | flags;
    resultParts = [
      webp.subarray(0, 20),
      new Uint8Array([newFlags]),
      webp.subarray(21, 30),
      ...(iccChunk ? [iccChunk] : []),
      webp.subarray(30),
      ...(exifChunk ? [exifChunk] : []),
      ...(xmpChunk ? [xmpChunk] : []),
    ];
  } else {
    const vp8x = new Uint8Array(18);
    vp8x[0] = 0x56; vp8x[1] = 0x50; vp8x[2] = 0x38; vp8x[3] = 0x58; // 'VP8X'
    vp8x[4] = 10; vp8x[5] = 0; vp8x[6] = 0; vp8x[7] = 0;            // payload size = 10
    vp8x[8] = flags; vp8x[9] = 0; vp8x[10] = 0; vp8x[11] = 0;
    const w = Math.max(width - 1, 0); vp8x[12] = w & 0xFF; vp8x[13] = (w >> 8) & 0xFF; vp8x[14] = (w >> 16) & 0xFF;
    const h = Math.max(height - 1, 0); vp8x[15] = h & 0xFF; vp8x[16] = (h >> 8) & 0xFF; vp8x[17] = (h >> 16) & 0xFF;
    resultParts = [
      webp.subarray(0, 12),
      vp8x,
      ...(iccChunk ? [iccChunk] : []),
      webp.subarray(12),
      ...(exifChunk ? [exifChunk] : []),
      ...(xmpChunk ? [xmpChunk] : []),
    ];
  }
  const totalLen = resultParts.reduce((s, p) => s + p.length, 0);
  const result = new Uint8Array(totalLen);
  let pos = 0;
  for (const part of resultParts) { result.set(part, pos); pos += part.length; }
  const riffSize = totalLen - 8;
  result[4] = riffSize & 0xFF; result[5] = (riffSize >> 8) & 0xFF; result[6] = (riffSize >> 16) & 0xFF; result[7] = (riffSize >> 24) & 0xFF;
  return result.buffer;
}

// ══════════════════════════════════════════════════════════
// ── 局部即時預覽編碼(Side-by-Side Canvas)─────────────────
// 接收 300×300 中央裁切的 RGBA,以「速度優先」參數快速編碼,
// 讓主執行緒能在拖動 Quality 滑桿時做無延遲畫質/大小比對。
// ══════════════════════════════════════════════════════════

async function processPreview({ id, rgba, width, height, format, quality }) {
  const t0 = performance.now();
  try {
    if (!initDone) throw new Error('engine not ready');
    const img = new ImageData(new Uint8ClampedArray(rgba), width, height);
    let buffer;
    const q = Math.min(Math.max(quality, 1), 100);
    switch (format) {
      case 'image/jpeg':
        if (!encoders.jpeg) throw new Error('JPEG encoder unavailable');
        // baseline + 無 trellis:300×300 約 5-15ms
        buffer = await encoders.jpeg.encode(img, { quality: q, progressive: false, smoothing: 0 });
        break;
      case 'image/webp':
        if (!encoders.webp) throw new Error('WebP encoder unavailable');
        buffer = await encoders.webp.encode(img, { quality: q, method: 2 });
        break;
      case 'image/png':
        if (!encoders.png) throw new Error('PNG encoder unavailable');
        buffer = await encoders.png.encode(img, { level: 2 });
        break;
      case 'image/avif': {
        if (!encoders.avif) throw new Error('AVIF encoder unavailable');
        const cqLevel = Math.round((1 - q / 100) * 63);
        buffer = await encoders.avif.encode(img, { cqLevel, speed: 10, subsample: 1 });
        break;
      }
      case 'image/jxl':
        if (!encoders.jxl) throw new Error('JXL encoder unavailable');
        buffer = q >= 100
          ? await encoders.jxl.encode(img, { lossless: true, effort: 1 })
          : await encoders.jxl.encode(img, { quality: q, effort: 1, lossless: false });
        break;
      case 'image/heif': {
        if (!encoders.heif) throw new Error('HEIF encoder unavailable');
        buffer = await nativeHeifEncode(img, q);
        break;
      }
      default:
        throw new Error(`Unsupported preview format: ${format}`);
    }
    self.postMessage(
      { type: 'PREVIEW_DONE', id, buffer, format, ms: Math.round(performance.now() - t0) },
      [buffer]
    );
  } catch (err) {
    self.postMessage({ type: 'PREVIEW_ERROR', id, error: err.message || 'preview failed' });
  }
}



// NOTE: All message handling is done via self.onmessage above.
