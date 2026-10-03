/**
 * main.js — 主執行緒控制器（HUD 版）
 *
 * 功能：
 *  - Worker Pool：根據 CPU 核心數自動建立多個 Worker
 *  - EXIF 保留：從原始檔提取 EXIF，壓縮後重新注入
 *  - 原始檔名：下載檔案保持原始名稱
 *  - HUD 儀表板：即時更新引擎狀態、佇列、已完成數、格式等
 *  - 壓縮計時 + 縮圖預覽
 */

// The page-bound markers are generated from package.json + generation.json.
// ABOUT consumes build-info.json; it never owns an independent release value.
const mainModuleUrl = new URL(import.meta.url);
const identityModuleUrl = new URL('./build-identity.mjs', mainModuleUrl);
identityModuleUrl.searchParams.set('v', mainModuleUrl.searchParams.get('v') || 'unverified');
identityModuleUrl.searchParams.set('b', mainModuleUrl.searchParams.get('b') || 'unverified');
const {
  classifyBuildIdentity,
  parseSemVer,
  sameBuildIdentity,
  validateBuildInfo,
  validateServiceWorkerStatus,
} = await import(identityModuleUrl.href);
const metaValue = name => document.querySelector(`meta[name="${name}"]`)?.content || '';
const pageGeneration = metaValue('nexpress-release-generation');
const pageBuildId = metaValue('nexpress-build-id');
const moduleGeneration = mainModuleUrl.searchParams.get('v') || '';
const moduleBuildId = mainModuleUrl.searchParams.get('b') || '';
const PAGE_RUNTIME_IDENTITY = Object.freeze({
  releaseGeneration: pageGeneration === moduleGeneration ? pageGeneration : '',
  buildId: pageBuildId === moduleBuildId ? pageBuildId : '',
  contentHash: metaValue('nexpress-content-hash'),
});
const APP_VERSION = parseSemVer(PAGE_RUNTIME_IDENTITY.releaseGeneration)
  ? PAGE_RUNTIME_IDENTITY.releaseGeneration
  : 'unverified';

const EXT_MAP = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/avif': 'avif', 'image/heif': 'heic', 'image/jxl': 'jxl' };
const FMT_LABEL = { 'image/jpeg': 'JPEG', 'image/png': 'PNG', 'image/webp': 'WebP', 'image/avif': 'AVIF', 'image/heif': 'HEIF', 'image/jxl': 'JXL' };
const FMT_SUB = { 'image/jpeg': 'compatibility', 'image/png': 'lossless', 'image/webp': 'high efficiency', 'image/avif': 'extreme', 'image/heif': 'Apple HEVC', 'image/jxl': 'archival' };
const TOTAL_CODEC_MODULES = 8; // jpeg·png·webp·avif·native heif·jxl·piexif·zip
const SUPPORTED_FORMATS = Object.keys(EXT_MAP);
const FORMAT_CAPABILITY = Object.fromEntries(SUPPORTED_FORMATS.map(format => [format, format]));

let selectedFormat = 'image/jpeg';
let pendingFiles = [];
let results = [];
let resultsGeneration = 0; // 批次世代戳:btnLaunch 重置時 +1,讓上一批 in-flight 的非同步預覽回寫失效
let totalOrig = 0, totalComp = 0, doneCount = 0, totalTasks = 0;
let batchStartTime = 0;
let batchRunning = false;
let batchCompleted = false;
let maxConcurrent = 3;
const fileMetaMap = new WeakMap();
const fileIdentityMap = new WeakMap();
const preReadFiles = new Map();
let nextFileIdentity = 1;
const deadLetters = []; // Dead Letter Queue:批次中被隔離的失敗任務(匯出錯誤報告用)

const $ = id => document.getElementById(id);
const fileInput = $('fileInput');
const uploadZone = $('uploadZone');
const qualitySlider = $('qualitySlider');
const qVal = $('qVal');
const qSuffix = $('qSuffix');
const qReadout = $('qReadout');
const qNote = $('qNote');
const btnLaunch = $('btnLaunch');
const terminal = $('terminal');
const resultsGrid = $('resultsGrid');
const statsBar = $('statsBar');
const btnDlAll = $('btnDlAll');
const avifWarn = $('avifWarn');
const heifWarn = $('heifWarn');
const concurrencySelect = $('concurrencySelect');
const tzToggle = $('tzToggle');
const tzSelect = $('tzSelect');
const tzCard = $('tzCard');
const tsToggle = $('tsToggle');   // 批次時間平移開關
const tsInput = $('tsInput');     // 平移量輸入("+8"、"-3:30"、"+5:45")
const tsCard = $('tsCard');
const tsHint = $('tsHint');
// The compression page is intentionally read-only for time and position.
// Keep legacy DOM hooks for the imported dashboard, but never enable writes.
tzToggle.checked = false;
tzToggle.disabled = true;
tsToggle.checked = false;
tsToggle.disabled = true;
const themeToggle = $('themeToggle');
const btnErrReport = $('btnErrReport'); // DLQ 錯誤報告匯出
const previewSec = $('previewSec');     // Side-by-Side 即時預覽
const pvOrig = $('pvOrig');
const pvComp = $('pvComp');
const pvMeta = $('pvMeta');
const pvEst = $('pvEst');
const instHw = $('instHw');
const instHwSub = $('instHwSub');
const whToggle = $('whToggle');   // Webhook 自動匯出
const whUrl = $('whUrl');
const whToken = $('whToken');
const whTest = $('whTest');
const whStatus = $('whStatus');
const cfgPwaStat = $('cfgPwaStat');
const cfgPwaCopy = $('cfgPwaCopy');
const aboutProductVersion = $('aboutProductVersion');
const aboutBuildState = $('aboutBuildState');
const aboutBuildReason = $('aboutBuildReason');
const aboutAppVersion = $('aboutAppVersion');
const aboutReleaseGeneration = $('aboutReleaseGeneration');
const aboutBuildId = $('aboutBuildId');
const aboutRevision = $('aboutRevision');
const aboutBuildTime = $('aboutBuildTime');
const aboutReleaseChannel = $('aboutReleaseChannel');
const aboutUpdateState = $('aboutUpdateState');
const aboutUpdateDetails = $('aboutUpdateDetails');
const batchEstimateStat = $('batchEstimateStat');
const batchEstimateCopy = $('batchEstimateCopy');
const navItems = [...document.querySelectorAll('.nav-item[data-view]')];
const viewPanels = [...document.querySelectorAll('.app-view[data-view-panel]')];
const changelogTrigger = $('changelogTrigger');
const changelogBack = $('changelogBack');

let buildIdentityAssessment = {
  state: 'UNVERIFIED',
  reason: 'Build metadata has not been checked yet.',
  current: null,
};

function renderBuildIdentity(assessment) {
  const build = assessment.current;
  if (aboutBuildState) {
    aboutBuildState.textContent = assessment.state;
    aboutBuildState.dataset.state = assessment.state;
  }
  if (aboutBuildReason) aboutBuildReason.textContent = assessment.reason;
  if (aboutProductVersion) aboutProductVersion.textContent = build ? `NEXPRESS ${build.appVersion}` : `NEXPRESS / ${assessment.state}`;
  if (aboutAppVersion) aboutAppVersion.textContent = build?.appVersion || 'UNKNOWN';
  if (aboutReleaseGeneration) aboutReleaseGeneration.textContent = build?.releaseGeneration || 'UNKNOWN';
  if (aboutBuildId) aboutBuildId.textContent = build?.buildId || 'UNKNOWN';
  if (aboutRevision) aboutRevision.textContent = build?.revision || 'UNKNOWN';
  if (aboutBuildTime) {
    aboutBuildTime.textContent = build?.builtAt || 'UNKNOWN';
    if (build) aboutBuildTime.dateTime = build.builtAt;
    else aboutBuildTime.removeAttribute('datetime');
  }
  if (aboutReleaseChannel) aboutReleaseChannel.textContent = build?.channel || 'UNKNOWN';
}

function setBuildIdentityAssessment(assessment) {
  buildIdentityAssessment = assessment;
  renderBuildIdentity(assessment);
  return assessment;
}

async function loadBuildIdentity() {
  const expected = PAGE_RUNTIME_IDENTITY;
  if (APP_VERSION === 'unverified' || !expected.buildId) {
    return setBuildIdentityAssessment(classifyBuildIdentity(expected, null, {
      kind: 'invalid', message: 'Page and main-module identity markers do not agree.',
    }));
  }
  const url = new URL('./build-info.json', mainModuleUrl);
  url.searchParams.set('v', APP_VERSION);
  url.searchParams.set('b', expected.buildId);
  let response;
  try {
    response = await fetch(url, { cache: 'no-cache', headers: { Accept: 'application/json' } });
  } catch (error) {
    return setBuildIdentityAssessment(classifyBuildIdentity(expected, null, {
      kind: 'unavailable', message: `Build metadata could not be loaded: ${error.message}`,
    }));
  }
  if (!response.ok) {
    return setBuildIdentityAssessment(classifyBuildIdentity(expected, null, {
      kind: 'unavailable', message: `Build metadata request failed with HTTP ${response.status}.`,
    }));
  }
  if (!/^application\/json(?:;|$)/i.test(response.headers.get('content-type') || '')) {
    return setBuildIdentityAssessment(classifyBuildIdentity(expected, null, {
      kind: 'invalid', message: 'Build metadata was not served as application/json.',
    }));
  }
  let candidate;
  try {
    candidate = await response.json();
  } catch {
    return setBuildIdentityAssessment(classifyBuildIdentity(expected, null, {
      kind: 'invalid', message: 'Build metadata is malformed JSON.',
    }));
  }
  return setBuildIdentityAssessment(classifyBuildIdentity(expected, candidate));
}

function markRuntimeIdentityMismatch(reason) {
  return setBuildIdentityAssessment({ state: 'MISMATCH', reason, current: null });
}

function renderPendingBuild(status) {
  if (!aboutUpdateState || !aboutUpdateDetails) return null;
  if (!status) {
    aboutUpdateState.textContent = 'NONE';
    aboutUpdateDetails.textContent = 'No verified waiting build is currently available.';
    return null;
  }
  const validated = validateServiceWorkerStatus(status);
  if (!validated.ok) {
    aboutUpdateState.textContent = 'UPDATE UNVERIFIED';
    aboutUpdateDetails.textContent = validated.errors.join('; ');
    return { state: 'UNVERIFIED', current: null };
  }
  const assessment = classifyBuildIdentity({
    releaseGeneration: status.generation,
    buildId: status.buildId,
    contentHash: status.contentHash,
  }, status.buildInfo);
  if (assessment.state === 'VERIFIED' && sameBuildIdentity(assessment.current, buildIdentityAssessment.current)) {
    aboutUpdateState.textContent = 'NONE';
    aboutUpdateDetails.textContent = 'The waiting worker describes the current running build.';
  } else if (assessment.state === 'VERIFIED') {
    aboutUpdateState.textContent = 'UPDATE READY';
    aboutUpdateDetails.textContent = `${assessment.current.appVersion} / ${assessment.current.buildId}`;
  } else {
    aboutUpdateState.textContent = `UPDATE ${assessment.state}`;
    aboutUpdateDetails.textContent = assessment.reason;
  }
  return assessment;
}

function reconcileControllerBuild(status) {
  const validated = validateServiceWorkerStatus(status);
  if (!validated.ok) {
    setBuildIdentityAssessment({ state: 'UNVERIFIED', reason: `Service Worker status is invalid: ${validated.errors.join('; ')}`, current: null });
    return false;
  }
  if (status.generation !== APP_VERSION
      || status.buildId !== PAGE_RUNTIME_IDENTITY.buildId
      || status.contentHash !== PAGE_RUNTIME_IDENTITY.contentHash) {
    markRuntimeIdentityMismatch('The controlling Service Worker does not match the current page-bound build.');
    return false;
  }
  if (buildIdentityAssessment.state === 'VERIFIED'
      && !sameBuildIdentity(status.buildInfo, buildIdentityAssessment.current)) {
    markRuntimeIdentityMismatch('The controlling Service Worker metadata does not match the verified current build.');
    return false;
  }
  return true;
}

const buildIdentityReady = loadBuildIdentity();

// HUD 儀表板元素
const instEngine = $('instEngine');
const ledEngine = $('ledEngine');
const instCodecs = $('instCodecs');
const instPoolSize = $('instPoolSize');
const instConc = $('instConc');
const instQueue = $('instQueue');
const queueBar = $('queueBar');
const instDone = $('instDone');
const instSaved = $('instSaved');
const instFmt = $('instFmt');
const instFmtSub = $('instFmtSub');
const HEIF_PREVIEW_PLACEHOLDER = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 4 3'%3E%3Crect width='4' height='3' fill='%230b1118'/%3E%3C/svg%3E";
const batchQueuedStat = $('batchQueuedStat');
const batchQueueCopy = $('batchQueueCopy');
const batchFormatStat = $('batchFormatStat');
const batchFormatCopy = $('batchFormatCopy');
const batchThreadStat = $('batchThreadStat');
const batchThreadCopy = $('batchThreadCopy');
const batchTimezoneStat = $('batchTimezoneStat');
const batchTimezoneCopy = $('batchTimezoneCopy');
const configFormatStat = $('configFormatStat');
const configFormatCopy = $('configFormatCopy');
const configQualityStat = $('configQualityStat');
const configQualityCopy = $('configQualityCopy');
const configThreadStat = $('configThreadStat');
const configThreadCopy = $('configThreadCopy');
const configTimezoneStat = $('configTimezoneStat');
const configTimezoneCopy = $('configTimezoneCopy');
const RESULT_MIN_WIDTH = 210;
const RESULT_GAP = 1;
const RESULT_ROW_HEIGHT = 309;
const RESULT_OVERSCAN_ROWS = 5;
const HEIF_PREVIEW_CONCURRENCY = 4;
const HEIF_PREVIEW_QUICK_WIDTH = 420;
const HEIF_PREVIEW_FULL_WIDTH = 960;
const resultsCanvas = document.createElement('div');
resultsCanvas.className = 'res-virtual-canvas';
let resultsRenderQueued = false;
let lastResultLayout = { columns: 1, width: 0 };
let heifPreviewActive = 0;
const heifPreviewQueue = [];
const renderedResultIndices = new Set();
let lastResultsScrollTop = 0;
let lastResultsScrollDirection = 1;
let currentDropToken = 0;

function getResultLayoutMetrics() {
  const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 1024;
  if (viewportWidth <= 560) {
    return { minWidth: 156, rowHeight: 392 };
  }
  if (viewportWidth <= 760) {
    return { minWidth: 172, rowHeight: 372 };
  }
  if (viewportWidth <= 1000) {
    return { minWidth: 190, rowHeight: 324 };
  }
  return { minWidth: RESULT_MIN_WIDTH, rowHeight: RESULT_ROW_HEIGHT };
}

function getFileMetaKey(file) {
  let identity = fileIdentityMap.get(file);
  if (!identity) {
    identity = `file-${nextFileIdentity++}`;
    fileIdentityMap.set(file, identity);
  }
  return identity;
}

function getPreReadId(file) {
  return `pre:${currentDropToken}:${getFileMetaKey(file)}:${crypto.randomUUID?.() || Math.random().toString(36).slice(2)}`;
}

function getFileMeta(file) {
  return fileMetaMap.get(file) || null;
}

function setFileMeta(file, meta) {
  fileMetaMap.set(file, meta);
}

function detectCameraBrand(camera) {
  if (!camera) return null;
  const value = camera.trim();
  if (!value) return null;
  const upper = value.toUpperCase();
  const knownBrands = ['CANON', 'NIKON', 'SONY', 'FUJIFILM', 'FUJI', 'LEICA', 'PENTAX', 'OLYMPUS', 'PANASONIC', 'LUMIX', 'RICOH', 'HASSELBLAD', 'DJI', 'GOPRO', 'SAMSUNG', 'APPLE', 'IPHONE', 'IPAD', 'GOOGLE', 'PIXEL', 'XIAOMI', 'HUAWEI', 'HONOR', 'OPPO', 'VIVO', 'ONEPLUS'];
  const match = knownBrands.find(brand => upper.includes(brand));
  if (!match) return value.split(/\s+/)[0]?.toUpperCase() || null;
  if (match === 'IPHONE' || match === 'IPAD') return 'APPLE';
  if (match === 'FUJI') return 'FUJIFILM';
  if (match === 'LUMIX') return 'PANASONIC';
  if (match === 'PIXEL') return 'GOOGLE';
  return match;
}

function getCameraModel(camera) {
  if (!camera) return null;
  const value = camera.trim();
  if (!value) return null;
  const brand = detectCameraBrand(value);
  if (!brand) return value;
  const upper = value.toUpperCase();
  const prefixes = [brand, 'APPLE', 'FUJIFILM', 'PANASONIC', 'GOOGLE'];
  for (const prefix of prefixes) {
    if (upper.startsWith(prefix)) {
      const trimmed = value.slice(prefix.length).trim();
      return trimmed || value;
    }
  }
  return value;
}

function mergeExifMeta(baseMeta, patchMeta) {
  return {
    camera: patchMeta?.camera ?? baseMeta?.camera ?? null,
    timezone: patchMeta?.timezone ?? baseMeta?.timezone ?? null,
    gps: patchMeta?.gps ?? baseMeta?.gps ?? null,
    dateTime: patchMeta?.dateTime ?? baseMeta?.dateTime ?? null,
    width: patchMeta?.width ?? baseMeta?.width ?? null,       // 預估引擎:實際像素尺寸
    height: patchMeta?.height ?? baseMeta?.height ?? null,
    complexity: patchMeta?.complexity ?? baseMeta?.complexity ?? null, // 色彩複雜度 0~1
  };
}

function formatExifSummary(meta) {
  if (!meta) return '';
  const parts = [];
  parts.push(meta.camera ? `${meta.camera}` : '未知相機');
  parts.push(meta.timezone ? `UTC: ${meta.timezone}` : '無偵測到時區');
  parts.push(meta.gps ? `GPS: ${meta.gps}` : '無 GPS 資訊');
  parts.push(meta.dateTime ? `${meta.dateTime}` : '無拍攝時間');
  return parts.join(' │ ');
}

function logTaskExifIfNeeded(task) {
  if (!task || task.exifLogged || !task.exifMeta) return;
  const summary = formatExifSummary(task.exifMeta);
  if (!summary) return;
  log('INFO', 'dim', `${task.file.name} │ EXIF │ ${summary}`);
  task.exifLogged = true;
}

function ensureResultsCanvas() {
  if (!resultsGrid.contains(resultsCanvas)) {
    resultsGrid.innerHTML = '';
    resultsGrid.appendChild(resultsCanvas);
  }
}

function createEmptyState() {
  const empty = document.createElement('div');
  empty.className = 'empty-state';
  empty.innerHTML = 'AWAITING INPUT <span class="empty-blink"></span>';
  return empty;
}

function queueResultsRender() {
  if (resultsRenderQueued) return;
  resultsRenderQueued = true;
  requestAnimationFrame(() => {
    resultsRenderQueued = false;
    renderResultsVirtual();
  });
}

function scoreHeifPreviewPriority(index, columns, scrollTop, viewportHeight) {
  const row = Math.floor(index / columns);
  const top = row * RESULT_ROW_HEIGHT;
  const center = top + RESULT_ROW_HEIGHT / 2;
  const viewportCenter = scrollTop + viewportHeight / 2;
  return Math.abs(center - viewportCenter);
}

/** HEIF 與 JXL 的 <img> 原生支援有限 → 走非同步解碼預覽管線 */
function isAsyncPreviewFormat(format) {
  return format === 'image/heif' || format === 'image/jxl';
}

function enqueueHeifPreview(result, priority) {
  if (!result || !isAsyncPreviewFormat(result.format)) return;
  const desiredStage = result.previewStage === 'quick' ? 'full' : 'quick';
  enqueueHeifPreviewStage(result, priority, desiredStage);
}

function enqueueHeifPreviewStage(result, priority, targetStage) {
  if (!result || !isAsyncPreviewFormat(result.format)) return;
  if (result.previewState === 'failed') return;
  if (result.previewStage === 'full') return;
  if (result.previewState === 'loading') {
    if (targetStage === 'full') result.previewTargetStage = 'full';
    return;
  }
  if (result.previewState === 'queued') {
    result.previewPriority = Math.min(result.previewPriority ?? Infinity, priority);
    if (targetStage === 'full') result.previewTargetStage = 'full';
    return;
  }
  result.previewState = 'queued';
  result.previewPriority = priority;
  result.previewTargetStage = targetStage;
  heifPreviewQueue.push(result);
}

function flushHeifPreviewQueue() {
  heifPreviewQueue.sort((a, b) => (a.previewPriority ?? Infinity) - (b.previewPriority ?? Infinity));
  while (heifPreviewActive < HEIF_PREVIEW_CONCURRENCY && heifPreviewQueue.length) {
    const next = heifPreviewQueue.shift();
    if (!next || next.previewState !== 'queued') continue;
    next.previewState = 'loading';
    heifPreviewActive++;
    hydrateHeifPreview(next).finally(() => {
      heifPreviewActive = Math.max(0, heifPreviewActive - 1);
      flushHeifPreviewQueue();
    });
  }
}

function updateResultCardPreview(result) {
  const card = result.cardEl;
  if (!card) return;
  const thumb = card.querySelector('.rc-thumb');
  if (!thumb) return;

  if (!isAsyncPreviewFormat(result.format)) {
    if (thumb.src !== result.url) thumb.src = result.url;
    return;
  }

  const fmtName = result.format === 'image/jxl' ? 'JXL' : 'HEIF';

  if (result.previewState === 'ready' && result.previewUrl) {
    if (thumb.src !== result.previewUrl) thumb.src = result.previewUrl;
    thumb.dataset.previewState = 'ready';
    thumb.dataset.previewStage = result.previewStage || 'quick';
    thumb.title = result.previewStage === 'full' ? `Compressed ${fmtName} preview` : `Compressed ${fmtName} quick preview`;
    thumb.alt = result.fileName;
    return;
  }

  if (result.previewState === 'failed') {
    if (thumb.src !== HEIF_PREVIEW_PLACEHOLDER) thumb.src = HEIF_PREVIEW_PLACEHOLDER;
    thumb.dataset.previewState = 'failed';
    thumb.alt = `${result.fileName} (${fmtName} preview unavailable)`;
    thumb.title = `This browser could not decode the compressed ${fmtName} preview. The file itself is valid.`;
    return;
  }

  if (thumb.src !== HEIF_PREVIEW_PLACEHOLDER) thumb.src = HEIF_PREVIEW_PLACEHOLDER;
  thumb.dataset.previewState = result.previewState || 'queued';
  thumb.dataset.previewStage = result.previewStage || 'idle';
  thumb.alt = `${result.fileName} (decoding ${fmtName} preview...)`;
  thumb.title = result.previewState === 'loading' ? `Decoding compressed ${fmtName} preview...` : `Queued compressed ${fmtName} preview...`;
}

function renderResultsVirtual() {
  if (!results.length) {
    resultsCanvas.innerHTML = ''; // 同步清掉重用 canvas 內的殘留卡片
    resultsGrid.innerHTML = '';
    resultsGrid.appendChild(createEmptyState());
    lastResultLayout = { columns: 1, width: 0 };
    return;
  }

  ensureResultsCanvas();

  const gridWidth = resultsGrid.clientWidth;
  const gridHeight = resultsGrid.clientHeight || 1;
  const { minWidth, rowHeight } = getResultLayoutMetrics();
  const columns = Math.max(1, Math.floor((gridWidth + RESULT_GAP) / (minWidth + RESULT_GAP)));
  const cardWidth = Math.max(minWidth, Math.floor((gridWidth - (columns - 1) * RESULT_GAP) / columns));
  const totalRows = Math.ceil(results.length / columns);
  const scrollTop = resultsGrid.scrollTop;
  const scrollDirection = scrollTop >= lastResultsScrollTop ? 1 : -1;
  lastResultsScrollTop = scrollTop;
  lastResultsScrollDirection = scrollDirection;
  const startRow = Math.max(0, Math.floor(scrollTop / rowHeight) - RESULT_OVERSCAN_ROWS);
  const endRow = Math.min(totalRows, Math.ceil((scrollTop + gridHeight) / rowHeight) + RESULT_OVERSCAN_ROWS);
  const startIndex = startRow * columns;
  const endIndex = Math.min(results.length, endRow * columns);
  const prefetchRows = RESULT_OVERSCAN_ROWS * 2;
  const prefetchStartRow = scrollDirection >= 0
    ? startRow
    : Math.max(0, startRow - prefetchRows);
  const prefetchEndRow = scrollDirection >= 0
    ? Math.min(totalRows, endRow + prefetchRows)
    : endRow;
  const prefetchStartIndex = prefetchStartRow * columns;
  const prefetchEndIndex = Math.min(results.length, prefetchEndRow * columns);

  resultsCanvas.style.height = `${Math.max(totalRows * rowHeight - RESULT_GAP, rowHeight)}px`;
  const nextRendered = new Set();
  for (let index = startIndex; index < endIndex; index++) {
    const result = results[index];
    if (result && isAsyncPreviewFormat(result.format)) {
      enqueueHeifPreview(result, scoreHeifPreviewPriority(index, columns, scrollTop, gridHeight));
      if (result.previewStage === 'quick' && result.previewState === 'ready') {
        enqueueHeifPreviewStage(result, scoreHeifPreviewPriority(index, columns, scrollTop, gridHeight) + 8, 'full');
      }
    }
    const card = createResultCard(result);
    const row = Math.floor(index / columns);
    const col = index % columns;
    card.style.position = 'absolute';
    card.style.width = `${cardWidth}px`;
    card.style.left = `${col * (cardWidth + RESULT_GAP)}px`;
    card.style.top = `${row * rowHeight}px`;
    if (card.parentNode !== resultsCanvas) resultsCanvas.appendChild(card);
    applyMarqueeIfNeeded(card);
    nextRendered.add(index);
  }

  for (let index = prefetchStartIndex; index < prefetchEndIndex; index++) {
    if (index >= startIndex && index < endIndex) continue;
    const result = results[index];
    if (result && isAsyncPreviewFormat(result.format)) {
      enqueueHeifPreviewStage(result, scoreHeifPreviewPriority(index, columns, scrollTop, gridHeight) + rowHeight, 'quick');
    }
  }

  renderedResultIndices.forEach((index) => {
    if (nextRendered.has(index)) return;
    const res = results[index];
    if (res) {
      const card = res.cardEl;
      if (card) {
        if (card.parentNode === resultsCanvas) {
          resultsCanvas.removeChild(card);
        }
        card._result = null;
      }
      if (res.previewUrl && res.previewUrl !== res.url) {
        URL.revokeObjectURL(res.previewUrl);
      }
      res.previewUrl = null;
      if (res.url) {
        URL.revokeObjectURL(res.url);
        res.url = null;
      }
      // previewState 'loading' 表示 hydrate 還在解碼中:保留狀態讓它完成後直接標 ready,
      // 若重設為 idle,卡片滾回視口會重複排一次完整解碼(浪費 CPU)
      if (isAsyncPreviewFormat(res.format) && res.previewState !== 'loading') {
        res.previewState = 'idle';
        res.previewStage = 'idle';
        res.previewTargetStage = 'quick';
      }
      res.cardEl = null;
    }
  });
  renderedResultIndices.clear();
  nextRendered.forEach(index => renderedResultIndices.add(index));
  lastResultLayout = { columns, width: cardWidth };
  flushHeifPreviewQueue();
}

function applyTheme(theme) {
  const isLight = theme === 'light';
  document.body.classList.toggle('light-theme', isLight);
  if (themeToggle) themeToggle.checked = isLight;
}

function loadThemePreference() {
  try {
    return localStorage.getItem('nexpress-theme') || 'dark';
  } catch {
    return 'dark';
  }
}

function saveThemePreference(theme) {
  try {
    localStorage.setItem('nexpress-theme', theme);
  } catch {}
}

async function nativeHeifBitmap(blob, maxWidth = 0) {
  const response = await fetch('./native/heif/decode', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/octet-stream',
      'X-Max-Width': String(maxWidth),
    },
    body: blob,
  });
  if (!response.ok) throw new Error((await response.text()).slice(0, 300));
  return createImageBitmap(await response.blob());
}

function getFormatRecommendation(format) {
  switch (format) {
    case 'image/png':
      return '無損輸出，適合圖表、截圖或需要透明背景的素材。';
    case 'image/webp':
      return '適合網站與一般分享，通常能拿到比 JPEG 更好的體積表現。';
    case 'image/avif':
      return '壓縮率最高，但編碼最慢，適合最終交付或封存版。';
    case 'image/heif':
      return 'macOS ImageIO 原生 HEVC，適合 Apple 生態；品質可調，輸出不保留來源 EXIF。';
    case 'image/jxl':
      return 'quality 100 為像素無損封存；瀏覽器預覽支援有限，輸出不保留 EXIF/ICC。';
    case 'image/jpeg':
    default:
      return '相容性最好，適合快速交付、社群平台與一般裝置。';
  }
}

function getThreadRecommendation(threads) {
  if (threads <= 1) return '低記憶體模式，適合舊機器或只想穩定處理單張。';
  if (threads <= 3) return '目前是均衡配置，兼顧速度與記憶體使用。';
  if (threads <= 5) return '偏高速配置，適合桌機與較新的筆電。';
  return '高並行模式，速度快但更吃 CPU 與記憶體。';
}

function getQualityRecommendation(quality) {
  if (quality >= 90) return '偏高畫質，保留更多細節，檔案縮減幅度通常會比較保守。';
  if (quality >= 75) return '目前設定在畫質與壓縮率之間的平衡點。';
  if (quality >= 55) return '偏向更積極的壓縮，適合網站圖與一般瀏覽用途。';
  return '壓縮較強，適合預覽圖、縮圖或對檔案大小很敏感的情境。';
}

function getTimezoneSummary() {
  const shiftOn = tsToggle?.checked;
  const shiftSuffix = shiftOn ? ` / 時間平移 ${tsInput?.value || '+0'}` : '';
  if (!tzToggle.checked) {
    return {
      title: shiftOn ? `SHIFT ${tsInput?.value || '+0'}` : 'OFF',
      copy: shiftOn
        ? `不覆寫時區,但所有 EXIF 時間欄位會平移 ${tsInput?.value || '+0'} 小時。`
        : '目前沒有覆寫嵌入式時區資料。'
    };
  }
  return {
    title: `UTC ${tzSelect.value}${shiftOn ? ' +SHIFT' : ''}`,
    copy: `輸出 JPEG 時會將 EXIF 時區覆寫成 ${tzSelect.options[tzSelect.selectedIndex].text}${shiftSuffix}。`
  };
}

function switchView(view, { silent = false } = {}) {
  navItems.forEach(item => {
    const active = item.dataset.view === view;
    item.classList.toggle('on', active);
    item.setAttribute('aria-selected', active ? 'true' : 'false');
  });
  viewPanels.forEach(panel => {
    panel.classList.toggle('is-active', panel.dataset.viewPanel === view);
  });
  if (!silent) {
    log('INFO', '', `View → ${view.toUpperCase()}`);
  }
}

function syncQualityUi() {
  qualitySlider.disabled = false;
  qReadout?.classList.remove('is-disabled');
  if (qSuffix) qSuffix.textContent = '/100';
  if (qVal) qVal.textContent = String(parseInt(qualitySlider.value, 10) || 82);
  if (qNote) {
    qNote.textContent = selectedFormat === 'image/heif'
      ? 'HEIF 使用 macOS ImageIO 原生 HEVC；品質可調，較高品質通常會增加檔案大小。'
      : (selectedFormat === 'image/jxl'
        ? 'JXL: quality 100 = 像素無損(封存);<100 = 有損模式。'
        : (selectedFormat === 'image/png'
          ? 'PNG 為無損格式:滑桿控制壓縮努力度(越高體積越小但越慢),畫質永遠不變。'
          : 'Quality slider is active for JPEG, WebP, and AVIF.'));
  }
  if (window.renderSegs) {
    window.renderSegs(parseInt(qualitySlider.value, 10) || 82);
  }
}

function refreshInfoViews() {
  const queuedFiles = pendingFiles.length;
  const formatLabel = FMT_LABEL[selectedFormat] || 'JPEG';
  const quality = parseInt(qualitySlider.value, 10) || 82;
  const timezoneSummary = getTimezoneSummary();
  const threadSummary = getThreadRecommendation(maxConcurrent);

  if (batchQueuedStat) batchQueuedStat.textContent = `${queuedFiles} file${queuedFiles === 1 ? '' : 's'}`;
  if (batchQueueCopy) {
    batchQueueCopy.textContent = queuedFiles
      ? `目前已緩衝 ${queuedFiles} 個檔案；按下 EXECUTE 後會依 worker pool 逐步分派，不需要重新選檔。`
      : '目前還沒有待處理檔案。拖入圖片後，這裡會告訴你這批素材會如何被排進 worker pool。';
  }
  if (batchFormatStat) batchFormatStat.textContent = formatLabel;
  if (batchFormatCopy) batchFormatCopy.textContent = getFormatRecommendation(selectedFormat);
  if (batchThreadStat) batchThreadStat.textContent = `${maxConcurrent} thread${maxConcurrent === 1 ? '' : 's'}`;
  if (batchThreadCopy) batchThreadCopy.textContent = threadSummary;
  if (batchTimezoneStat) batchTimezoneStat.textContent = timezoneSummary.title;
  if (batchTimezoneCopy) batchTimezoneCopy.textContent = timezoneSummary.copy;

  if (configFormatStat) configFormatStat.textContent = formatLabel;
  if (configFormatCopy) configFormatCopy.textContent = getFormatRecommendation(selectedFormat);
  if (configQualityStat) configQualityStat.textContent = `${quality} / 100`;
  if (configQualityCopy) configQualityCopy.textContent = getQualityRecommendation(quality);
  if (configThreadStat) configThreadStat.textContent = String(maxConcurrent);
  if (configThreadCopy) configThreadCopy.textContent = threadSummary;
  if (configTimezoneStat) configTimezoneStat.textContent = timezoneSummary.title;
  if (configTimezoneCopy) configTimezoneCopy.textContent = timezoneSummary.copy;
}


// ══════════════════════════════════════════════════════════
// ── EXIF 提取與注入工具 ──────────────────────────────────
// (已移至 worker.js 以節省主執行緒記憶體與避免阻塞)
// ══════════════════════════════════════════════════════════

function getOutputFileName(originalName, outputExt) {
  const dotIndex = originalName.lastIndexOf('.');
  const baseName = dotIndex === -1 ? originalName : originalName.substring(0, dotIndex);
  const origExt  = dotIndex === -1 ? '' : originalName.substring(dotIndex + 1);

  const targetExt = outputExt.toLowerCase();

  // If same format (handles jpg/jpeg equivalence), keep the original name untouched
  const isJpeg = (e) => e.toLowerCase() === 'jpg' || e.toLowerCase() === 'jpeg';
  if (origExt.toLowerCase() === targetExt || (isJpeg(origExt) && isJpeg(targetExt))) {
    return originalName;
  }

  // Otherwise replace just the extension, preserve the original base name exactly
  return `${baseName}.${targetExt}`;
}


// ══════════════════════════════════════════════════════════
// ── Worker Pool (動態擴縮) ───────────────────────────────
// ══════════════════════════════════════════════════════════

const workerPool = [];
const respawnTimestamps = []; // 崩潰迴圈斷路器:全池 30s 滑動視窗內的重生時間戳
let readyWorkers = 0;
let codecsLoaded = 0;
let initDone = false;
let settleInitialEngine;
let initialEngineSettled = false;
const initialEngineReady = new Promise(resolve => { settleInitialEngine = resolve; });
let taskMap = {};
const MAX_TASK_RETRIES = 1;
let zipReady = typeof window.JSZip === 'function';

function requiredTaskFormat(task) {
  return task?.msg?.type === 'COMPRESS' || task?.msg?.type === 'PREVIEW_ENCODE'
    ? task.msg.format
    : null;
}

function slotCanRunTask(slot, task) {
  if (!slot?.ready) return false;
  const format = requiredTaskFormat(task);
  return !format || slot.capabilities?.formats?.[format] === true;
}

function formatWorkerCapacity(format) {
  return workerPool.filter(slot => slot.ready && slot.capabilities?.formats?.[format] === true).length;
}

function slotHasFullCapability(slot) {
  return Boolean(slot?.ready && slot.capabilities?.exif && SUPPORTED_FORMATS.every(format => slot.capabilities?.formats?.[format] === true));
}

function refreshCapabilityState() {
  zipReady = typeof window.JSZip === 'function';
  const readySlots = workerPool.filter(slot => slot.ready);
  const formatCount = SUPPORTED_FORMATS.filter(format => formatWorkerCapacity(format) > 0).length;
  const exifReady = readySlots.some(slot => slot.capabilities?.exif);
  const moduleCount = formatCount + (exifReady ? 1 : 0) + (zipReady ? 1 : 0);

  document.querySelectorAll('.fmt-chip').forEach(chip => {
    const available = formatWorkerCapacity(chip.dataset.fmt) > 0;
    chip.disabled = !available;
    chip.setAttribute('aria-disabled', available ? 'false' : 'true');
    chip.setAttribute('aria-pressed', chip.dataset.fmt === selectedFormat ? 'true' : 'false');
    chip.title = available ? '' : `${FMT_LABEL[chip.dataset.fmt] || chip.dataset.fmt} encoder unavailable`;
  });
  if (instCodecs) {
    instCodecs.textContent = `${moduleCount} / ${TOTAL_CODEC_MODULES}`;
    instCodecs.className = moduleCount === TOTAL_CODEC_MODULES ? 'inst-val' : 'inst-val amber';
  }

  if (readySlots.length === workerPool.length && readySlots.length > 0) {
    initDone = true;
    const fullyReady = moduleCount === TOTAL_CODEC_MODULES && readySlots.every(slotHasFullCapability);
    if (instEngine) {
      instEngine.textContent = fullyReady ? 'ONLINE' : 'DEGRADED';
      instEngine.className = fullyReady ? 'inst-val' : 'inst-val amber';
    }
    if (ledEngine) ledEngine.className = fullyReady ? 'inst-led on' : 'inst-led blink';
  } else if (initDone && workerPool.length > 0) {
    if (instEngine) {
      instEngine.textContent = 'RECOVERING';
      instEngine.className = 'inst-val amber';
    }
    if (ledEngine) ledEngine.className = 'inst-led blink';
  }
  const selectedAvailable = formatWorkerCapacity(selectedFormat) > 0;
  if (pendingFiles.length && !batchRunning) {
    btnLaunch.disabled = !selectedAvailable || readyWorkers < workerPool.length;
  }
}

// ══════════════════════════════════════════════════════════
// ── 優先級佇列(Priority Queue)────────────────────────────
// 二元最小堆積:priority 低者先出;同 priority 依進入順序(seq)穩定排序。
// 取代原本的 FIFO array — 小體積 JPEG 先跑、巨檔與 HEIC/AVIF 靠後,
// 進度條視覺流暢度大幅提升。push/shift O(log n),不再有 O(n) 的 unshift。
// ══════════════════════════════════════════════════════════

const PRIORITY = {
  RETRY: -1,          // 崩潰重試:插隊到最前
  PREVIEW: 0,         // 即時預覽:使用者正在拖滑桿,絕對優先
  EXIF_READ: 1_000,   // EXIF 預讀:輕量、需要快速回饋
  COMPRESS: 10_000,   // 壓縮任務:基準值 + 成本權重
};

class PriorityQueue {
  constructor() { this.heap = []; this.seq = 0; }
  get length() { return this.heap.length; }
  push(task) {
    if (task.priority === undefined) task.priority = computeTaskPriority(task.msg);
    // 只在任務「第一次」入隊時配發 _seq。filter() 會透過 push() 把倖存任務搬進
    // 新的堆積,若在此重新配發 _seq,配發順序取決於「堆積內部陣列順序」
    // (heap-shape,非優先權排序也非原始插入順序)—— 會讓同優先權任務的
    // 穩定排序(依進入順序)失真。保留既有 _seq 才能維持 filter() 前後一致。
    if (task._seq === undefined) task._seq = this.seq++;
    this.heap.push(task);
    this._up(this.heap.length - 1);
    return this;
  }
  shift() {
    if (!this.heap.length) return undefined;
    const top = this.heap[0];
    const last = this.heap.pop();
    if (this.heap.length) { this.heap[0] = last; this._down(0); }
    return top;
  }
  unshift(task) { task.priority = PRIORITY.RETRY; return this.push(task); }
  filter(fn) {
    const next = new PriorityQueue();
    next.seq = this.seq;
    for (const t of this.heap) { if (fn(t)) next.push(t); }
    return next;
  }
  some(fn) { return this.heap.some(fn); }
  _less(a, b) {
    const pa = this.heap[a], pb = this.heap[b];
    return pa.priority !== pb.priority ? pa.priority < pb.priority : pa._seq < pb._seq;
  }
  _up(i) {
    while (i > 0) {
      const parent = (i - 1) >> 1;
      if (!this._less(i, parent)) break;
      [this.heap[i], this.heap[parent]] = [this.heap[parent], this.heap[i]];
      i = parent;
    }
  }
  _down(i) {
    const n = this.heap.length;
    for (;;) {
      let m = i;
      const l = 2 * i + 1, r = 2 * i + 2;
      if (l < n && this._less(l, m)) m = l;
      if (r < n && this._less(r, m)) m = r;
      if (m === i) break;
      [this.heap[i], this.heap[m]] = [this.heap[m], this.heap[i]];
      i = m;
    }
  }
}

/** 計算任務優先級:小體積 JPEG 最優先;HEIC 來源、AVIF/HEIF 輸出等重任務靠後。 */
function computeTaskPriority(msg) {
  if (!msg) return PRIORITY.COMPRESS;
  if (msg.type === 'PREVIEW_ENCODE') return PRIORITY.PREVIEW;
  if (msg.type === 'EXIF_READ_ONLY') return PRIORITY.EXIF_READ;
  let weight = 0;
  const f = msg.file;
  if (f) {
    weight += Math.min(f.size || 0, 30_000_000); // 檔案大小權重(上限 30MB)
    const name = (f.name || '').toLowerCase();
    const isHeicSource = f.type === 'image/heic' || f.type === 'image/heif' ||
      name.endsWith('.heic') || name.endsWith('.heif');
    if (isHeicSource) weight += 50_000_000;      // HEIC 解碼昂貴 → 靠後
  }
  if (msg.format === 'image/avif' || msg.format === 'image/heif') weight += 30_000_000; // 慢速編碼器
  else if (msg.format === 'image/jxl' && msg.quality >= 100) weight += 10_000_000;      // lossless 較慢
  return PRIORITY.COMPRESS + weight;
}

let taskQueue = new PriorityQueue();

// ══════════════════════════════════════════════════════════
// ── 記憶體壓力監控(Memory Pressure Observer)──────────────
// performance.memory(Chromium)+ in-flight payload 啟發式,
// 動態下修有效並行數,防止大批巨檔造成 OOM 崩潰。
// ══════════════════════════════════════════════════════════

let dynamicConcurrencyCap = Infinity;
let lastPressureState = 'normal';

function effectiveConcurrent() {
  return Math.max(1, Math.min(maxConcurrent, dynamicConcurrencyCap));
}

function inflightPayloadBytes() {
  let sum = 0;
  for (const slot of workerPool) {
    const f = slot.currentTask?.msg?.file;
    if (f && slot.currentTask.msg.type === 'COMPRESS') sum += f.size || 0;
  }
  return sum;
}

function assessMemoryPressure() {
  let state = 'normal';
  try {
    if (performance.memory) {
      const ratio = performance.memory.usedJSHeapSize / performance.memory.jsHeapSizeLimit;
      if (ratio > 0.8) state = 'critical';
      else if (ratio > 0.65) state = 'elevated';
    }
    // 沿用原版批次策略：觀察實際 heap 與正在處理的壓縮檔 payload，
    // 壓力升高時動態降低並行數，不因單張圖片的解碼尺寸直接拒絕任務。
    const inflight = inflightPayloadBytes();
    if (inflight > 400_000_000) state = 'critical';
    else if (inflight > 200_000_000 && state === 'normal') state = 'elevated';
  } catch { /* performance.memory 不存在(非 Chromium)→ 僅用 payload 啟發式 */ }

  const prevCap = dynamicConcurrencyCap;
  if (state === 'critical') dynamicConcurrencyCap = 1;
  else if (state === 'elevated') dynamicConcurrencyCap = Math.max(1, Math.ceil(maxConcurrent / 2));
  else dynamicConcurrencyCap = Infinity;

  if (state !== lastPressureState) {
    if (state !== 'normal') {
      log('WARN', 'wrn', `記憶體壓力 ${state.toUpperCase()} — 並行數暫時調降為 ${effectiveConcurrent()}`);
    } else if (lastPressureState !== 'normal') {
      log('OK', 'ok', `記憶體壓力解除 — 並行數恢復為 ${maxConcurrent}`);
    }
    lastPressureState = state;
    updateConcurrencyHud();
    if (prevCap !== dynamicConcurrencyCap) drainQueue();
  }
}

function updateConcurrencyHud() {
  const eff = effectiveConcurrent();
  if (!instConc) return;
  if (eff < maxConcurrent) {
    instConc.textContent = `${eff}/${maxConcurrent}`;
    instConc.className = 'inst-val amber';
  } else {
    instConc.textContent = String(maxConcurrent);
    instConc.className = 'inst-val blue';
  }
}

setInterval(assessMemoryPressure, 1500);

function updateHudQueue() {
  const qLen = taskQueue.length;
  const busy = workerPool.filter(s => s.busy).length;
  const totalActive = qLen + busy;
  const queueBase = totalTasks > 0 ? totalTasks : Math.max(pendingFiles.length, totalActive, 1);
  const queuePct = Math.min(100, (totalActive / queueBase) * 100);
  instQueue.textContent = totalActive;
  queueBar.style.width = `${queuePct}%`;
}

function clearSlotTask(slot) {
  slot.busy = false;
  slot.currentTask = null;
  // 縮池時因忙碌而躲過回收的 worker:任務結束的此刻補收
  if (workerPool.length > maxConcurrent) maybeShrinkPool();
}

/** 把 pool 收斂回 maxConcurrent:只砍閒置 worker,忙碌者留待其 clearSlotTask 補收 */
function maybeShrinkPool() {
  let changed = false;
  for (let i = workerPool.length - 1; i >= 0 && workerPool.length > maxConcurrent; i--) {
    const s = workerPool[i];
    if (s.busy) continue;
    try { s.worker.terminate(); } catch {}
    if (s.ready) { readyWorkers = Math.max(0, readyWorkers - 1); s.ready = false; s.capabilities = null; }
    workerPool.splice(i, 1);
    changed = true;
  }
  if (changed) {
    workerPool.forEach((s, idx) => s.index = idx);
    instPoolSize.textContent = `×${workerPool.length}`;
    refreshCapabilityState();
  }
}

function recordDeadLetter(fileName, size, reason, attempts) {
  deadLetters.push({
    fileName: fileName || 'unknown',
    size: size ?? null,
    reason: String(reason || 'unknown error'),
    attempts: attempts ?? 1,
    when: new Date().toISOString(),
  });
}

function failQueuedTask(task, reason) {
  if (!task?.msg?.id) return;
  const id = task.msg.id;
  // PREVIEW_ENCODE 不進 taskMap,但仍需清掉 preview.inflightId,
  // 否則 preview.schedule() 會永遠卡在「inflight」判斷、live preview 整個 session 失效。
  if (task.msg.type === 'PREVIEW_ENCODE') {
    handlePreviewError({ id, error: reason });
    return;
  }
  if (task.msg.type === 'EXIF_READ_ONLY') {
    preReadFiles.delete(id);
    log('WARN', 'wrn', `Metadata pre-read failed: ${reason}`);
    return;
  }
  const tracked = taskMap[id];
  removeProg(id);
  log('ERR', 'err', `${tracked ? tracked.file.name : 'task'} failed: ${reason}`);
  if (tracked) {
    recordDeadLetter(tracked.file?.name, tracked.origSize, reason, (task.retryCount || 0) + 1);
    delete taskMap[id];
    doneCount++;
    if (doneCount >= totalTasks) onBatchComplete();
  }
}

function recoverCrashedTask(slot, reason) {
  const task = slot.currentTask;
  if (!task) return;

  clearSlotTask(slot);

  // Transfer 型任務(目前只有 PREVIEW_ENCODE)攜帶的 ArrayBuffer 在第一次
  // postMessage 時已被瀏覽器 detach,無法重新塞回佇列重送(會拋 DataCloneError,
  // 而且是在 freeSlot.busy=true 設定之後拋出,把整個 worker slot 永久卡死)。
  // 這類任務崩潰就直接判定失敗,不重試。
  if (task.transfer && task.transfer.length) {
    failQueuedTask(task, reason);
    return;
  }

  task.retryCount = (task.retryCount || 0) + 1;
  if (task.retryCount <= MAX_TASK_RETRIES) {
    taskQueue.unshift(task);
    log('WARN', 'wrn', `Retrying ${task.msg.type} after worker crash (${task.retryCount}/${MAX_TASK_RETRIES})`);
    return;
  }

  failQueuedTask(task, reason);
}

/**
 * libjxl 的 Emscripten instance 在 Aborted() 後會進入不可用狀態；同一個
 * Worker 內降低 effort 再試只會得到相同錯誤。此處是可預期的單檔降級路徑，
 * 不計入「Worker 意外崩潰」的斷路器，直接用乾淨 Worker 重送 Q99 任務。
 */
function replaceWorkerForJxlRecovery(slot) {
  try { slot.worker.terminate(); } catch {}
  if (slot.ready) {
    readyWorkers = Math.max(0, readyWorkers - 1);
    slot.ready = false;
    slot.capabilities = null;
  }
  const pos = workerPool.indexOf(slot);
  if (pos === -1) return;
  log('SYS', 'dim', `Recycling worker #${pos} for JXL near-lossless recovery...`);
  workerPool[pos] = createWorkerSlot(pos);
  instPoolSize.textContent = `×${workerPool.length}`;
  refreshCapabilityState();
  updateHudQueue();
  drainQueue();
}

function createWorkerSlot(index) {
  // 固定版本 buster:Date.now() 會讓每個 worker 的 URL 都不同,
  // 破壞 HTTP 快取與 Service Worker 離線快取(PWA 關鍵修復)
  const workerUrl = new URL('./worker.js', mainModuleUrl);
  workerUrl.searchParams.set('v', APP_VERSION);
  workerUrl.searchParams.set('b', PAGE_RUNTIME_IDENTITY.buildId || 'unverified');
  const w = new Worker(workerUrl, { type: 'module' });
  const slot = { worker: w, busy: false, index, currentTask: null, ready: false, incompatible: false, capabilities: null };

  w.onmessage = ({ data }) => {
    switch (data.type) {
      case 'INIT_PROGRESS':
        if (index === 0) {
          const modulePosition = `${data.index || '?'}/${data.total || '?'}`;
          const moduleName = `${data.label || data.name || 'MODULE'} / ${data.engine || 'runtime'}`;
          if (data.status === 'loading') {
            log('SYS', 'dim', `  [${modulePosition}] ${moduleName} — 載入中；${data.purpose || '初始化執行模組'}`);
          } else if (data.status === 'ready') {
            log('OK', 'dim', `  [${modulePosition}] ${moduleName} — READY (${data.elapsedMs ?? 0} ms)`);
          } else if (data.status === 'failed') {
            log('WARN', 'wrn', `  [${modulePosition}] ${moduleName} — FAILED (${data.elapsedMs ?? 0} ms)：${data.error || 'unknown error'}`);
          } else {
            log('SYS', 'dim', data.msg || `${moduleName} initialization update`);
          }
          // 只以實際 READY 計數；Worker 重生不重複灌入首次啟動 HUD。
          if (!initDone && data.status === 'ready') {
            codecsLoaded++;
            if (instCodecs) {
              instCodecs.textContent = `${Math.min(codecsLoaded, TOTAL_CODEC_MODULES)} / ${TOTAL_CODEC_MODULES}`;
              instCodecs.className = 'inst-val amber';
            }
          }
        }
        break;
      case 'READY':
        if (slot.ready) break; // duplicate READY must not inflate pool readiness
        if (data.generation !== APP_VERSION || data.buildId !== PAGE_RUNTIME_IDENTITY.buildId) {
          slot.incompatible = true;
          try { w.terminate(); } catch {}
          markRuntimeIdentityMismatch(`Worker #${index} does not match the current page-bound build.`);
          if (instEngine) {
            instEngine.textContent = 'MISMATCH';
            instEngine.className = 'inst-val red';
          }
          if (ledEngine) ledEngine.className = 'inst-led err';
          if (btnLaunch) btnLaunch.disabled = true;
          log('ERR', 'err', `Worker #${index} build mismatch; refusing mixed runtime generation`);
          break;
        }
        slot.ready = true;
        slot.capabilities = data.capabilities || { formats: {}, exif: false };
        readyWorkers++;
        refreshCapabilityState();
        if (readyWorkers === workerPool.length) {
          const unavailable = SUPPORTED_FORMATS.filter(format => formatWorkerCapacity(format) === 0);
          const partialSlots = workerPool.filter(slot => !slotHasFullCapability(slot));
          if (unavailable.length || !zipReady || partialSlots.length) {
            log('WARN', 'wrn', `Engine degraded — unavailable: ${[
              ...unavailable.map(format => FMT_LABEL[format]),
              ...(!zipReady ? ['ZIP'] : []),
              ...(partialSlots.length ? [`${partialSlots.length} partial worker(s)`] : []),
            ].join(', ') || 'reduced capability'}`);
          } else {
            log('OK', 'ok', `Compression engine online — ${workerPool.length} workers ready (${TOTAL_CODEC_MODULES} modules)`);
          }
          if (!initialEngineSettled) {
            initialEngineSettled = true;
            settleInitialEngine({ state: unavailable.length || !zipReady || partialSlots.length ? 'DEGRADED' : 'ONLINE' });
          }
        } else {
          if (instEngine) instEngine.textContent = `${readyWorkers}/${workerPool.length}`;
        }
        // 佇列中可能已有等待的任務(EXIF 預讀/預覽)— worker 就緒後立即派工
        drainQueue();
        // 引擎上線前拖入的檔案:此刻補發即時預覽編碼
        if (initDone && preview.master && !preview.inflightId) preview.schedule();
        break;
      case 'INIT_ERROR':
        instEngine.textContent = 'ERROR';
        instEngine.className = 'inst-val red';
        ledEngine.className = 'inst-led err';
        log('ERR', 'err', `Worker #${index} init failed: ${data.error}`);
        if (!initialEngineSettled) {
          initialEngineSettled = true;
          settleInitialEngine({ state: 'ERROR', error: data.error });
        }
        refreshCapabilityState();
        break;
      case 'TASK_START':
        if (slot.currentTask?.msg?.id === data.id) {
          const task = taskMap[data.id];
          if (task) {
            if (!task.processStartTime) task.processStartTime = performance.now();
            log('PROC', 'dim', `Worker #${index} 開始編碼 ${task.file.name}`);
          }
        }
        updateProg(data.id, data.pct || 5, data.status || '處理中...');
        break;
      case 'TASK_PROGRESS':
        updateProg(data.id, data.pct || 50, data.status || '壓縮中...');
        break;
      case 'EXIF_META': {
        const m = data.meta;
        const task = taskMap[data.id];
        const isPreRead = data.id.startsWith('pre:');
        const summary = formatExifSummary(m);

        if (isPreRead) {
            if (data.requestToken !== currentDropToken) {
              preReadFiles.delete(data.id);
              clearSlotTask(slot);
              updateHudQueue();
              drainQueue();
              break;
            }
            const fileObj = preReadFiles.get(data.id);
            preReadFiles.delete(data.id);
            const fileName = fileObj?.name || 'unknown';
            const sizeStr = fileObj ? fmtBytes(fileObj.size) : '';
            if (fileObj) {
              setFileMeta(fileObj, mergeExifMeta(getFileMeta(fileObj), m));
              estimator.refreshBatchEstimate(); // 尺寸到手 → 更新預估
            }

            if (summary) {
              log('SYS', 'dim', `${fileName} (${sizeStr}) │ ${summary}`);
            } else {
              if (m && m.bytes) {
                log('SYS', 'dim', `${fileName} (${sizeStr}) │ 無設備/GPS/時區資訊`);
              } else {
                log('SYS', 'dim', `${fileName} (${sizeStr})`);
              }
            }
            if (m && m.animated) {
              log('WARN', 'wrn', `${fileName} 為動畫圖 — 壓縮輸出僅保留第一幀`);
            }

            clearSlotTask(slot);
            updateHudQueue();
            drainQueue();
        } else {
            if (task?.file && m) {
              task.exifMeta = mergeExifMeta(task.exifMeta, m);
            }
        }
        break;
      }
      case 'TASK_DONE': {
        const { id, buffer, format } = data;
        const task = taskMap[id];
        if (!task) break;
        const { file, origSize, startTime, processStartTime } = task;
        const elapsed = ((performance.now() - (processStartTime || startTime)) / 1000).toFixed(1);

        const compSize = buffer.byteLength;
        const ratio = ((1 - compSize / origSize) * 100).toFixed(1);
        const ext = EXT_MAP[format] || 'bin';
        const fileName = getOutputFileName(file.name, ext);
        const blob = new Blob([buffer], { type: format });
        // 原始檔與壓縮檔的 blob URL 只在需要時才 lazily createObjectURL, 關閉或滑出畫面後釋放。
        // HEIF/JXL:瀏覽器 <img> 多半無法直接顯示 → 走非同步預覽管線
        const needsAsyncPreview = format === 'image/heif' || format === 'image/jxl';
        const result = {
          file,
          gen: resultsGeneration, // 所屬批次世代:hydrate 完成時比對,防孤兒回寫
          origSize,
          compSize,
          url: null,
          previewUrl: null,
          previewState: needsAsyncPreview ? 'idle' : 'ready',
          previewStage: needsAsyncPreview ? 'idle' : 'full',
          previewTargetStage: needsAsyncPreview ? 'quick' : 'full',
          fileName,
          blob,
          format,
          ratio,
          elapsed,
          timezone: data.timezone,
          timeShift: null,
          metadataStatus: data.metadataStatus,
          jxlRecovery: Boolean(data.jxlRecovery),
          effectiveQuality: data.effectiveQuality ?? task.quality,
          exifMeta: task.exifMeta
        };
        totalOrig += origSize; totalComp += compSize; doneCount++;
        updateProg(id, 100, 'DONE');
        log('OK', 'ok', `${file.name}  →  ${fileName}`);
        log('SYS', 'dim', `${fmtBytes(origSize)} → ${fmtBytes(compSize)}   saved ${ratio}%   [${elapsed}s]`);
        if (data.metadataStatus) log(data.metadataStatus.includes('不保留') || data.metadataStatus.includes('無法') ? 'WARN' : 'INFO',
          data.metadataStatus.includes('不保留') || data.metadataStatus.includes('無法') ? 'wrn' : 'inf',
          `${fileName}：${data.metadataStatus}`);
        if (data.jxlRecovery) {
          log('WARN', 'wrn', `${fileName}：無損 JXL 編碼失敗，已改用 JXL quality 99 近無損輸出`);
        }
        logTaskExifIfNeeded(task);
        if (data.timezone && task.modifyTz) log('INFO', 'inf', `Timezone adjusted to ${data.timezone} for ${fileName}`);
        if (data.timeShift) log('INFO', 'inf', `Capture time shifted by ${formatShiftLabel(data.timeShift)} for ${fileName}`);
        // 預估引擎:記錄實際 bpp,校準後續預測
        if (data.width && data.height) {
          estimator.recordActual(format, data.effectiveQuality ?? task.quality ?? 0, task.complexity, compSize, data.width * data.height);
          // 讓剛完成的真實輸出立刻參與下一次估算，不必等到使用者再次拖動滑桿。
          estimator.refreshBatchEstimate(true);
        }
        addResultCard(result);
        updateStats();
        delete taskMap[id];

        // HUD 更新
        instDone.textContent = doneCount;
        const savedPct = totalOrig > 0 ? ((1 - totalComp / totalOrig) * 100).toFixed(1) + '%' : '—';
        instSaved.textContent = savedPct;

        clearSlotTask(slot);
        updateHudQueue();
        drainQueue();
        if (doneCount >= totalTasks) onBatchComplete();
        break;
      }
      case 'TASK_JXL_NEAR_LOSSLESS_RETRY': {
        const task = slot.currentTask;
        const tracked = taskMap[data.id];
        // 忽略舊 Worker 在任務已結束或已被回收後延遲送達的訊息，避免重複入隊。
        if (!task || task.msg.id !== data.id || !tracked || task.msg.jxlRecovery) break;

        task.retryCount = (task.retryCount || 0) + 1;
        task.msg.jxlRecovery = true;
        taskQueue.unshift(task);
        updateProg(data.id, 65, 'JXL Q99 RECOVERY...');
        log('WARN', 'wrn', `${tracked.file.name}：JXL 無損編碼中止 (${data.error})；改用 quality 99 近無損重試 (2/2)`);
        clearSlotTask(slot);
        replaceWorkerForJxlRecovery(slot);
        break;
      }
      case 'TASK_ERROR': {
        const t = taskMap[data.id];
        removeProg(data.id);
        log('ERR', 'err', `${t ? t.file.name : 'task'} failed: ${data.error}`);
        if (t) {
          // 壞檔隔離(DLQ):單一損毀檔案不中斷批次,記錄後匯出錯誤報告
          recordDeadLetter(t.file?.name, t.origSize, data.error, (slot.currentTask?.retryCount || 0) + 1);
          delete taskMap[data.id];
          doneCount++;
          instDone.textContent = doneCount; // 失敗也計入,避免最後一檔失敗時 HUD 停在 N-1
        }
        clearSlotTask(slot);
        updateHudQueue();
        drainQueue();
        if (doneCount >= totalTasks) onBatchComplete();
        break;
      }
      case 'PREVIEW_DONE':
        handlePreviewDone(data);
        clearSlotTask(slot);
        updateHudQueue();
        drainQueue();
        break;
      case 'PREVIEW_ERROR':
        handlePreviewError(data);
        clearSlotTask(slot);
        updateHudQueue();
        drainQueue();
        break;
    }
  };

  const respawn = (reason) => {
    log('ERR', 'err', `Worker crashed: ${reason}`);
    recoverCrashedTask(slot, `Worker crashed: ${reason}`);
    try { slot.worker.terminate(); } catch {}
    if (slot.ready) { readyWorkers = Math.max(0, readyWorkers - 1); slot.ready = false; slot.capabilities = null; }
    // 用當前位置而非建立時的閉包 index:pool 縮減 splice 後 index 會位移,
    // 以舊 index 覆寫會砍錯 slot。必須在 recoverCrashedTask 之後才取:
    // 其中的 clearSlotTask 可能觸發 maybeShrinkPool 改動陣列(splice 本 slot)。
    const pos = workerPool.indexOf(slot);
    if (pos !== -1) {
      // 崩潰迴圈斷路器:worker.js 本身載入失敗(離線未快取/檔案損毀)時,
      // 新生 worker 會立刻再觸發 onerror → 無限重生+日誌洗版。
      // 30 秒內全池累計崩潰 6 次即停止重生,標記引擎故障(loud failure)。
      const now = Date.now();
      respawnTimestamps.push(now);
      while (respawnTimestamps.length && now - respawnTimestamps[0] > 30_000) respawnTimestamps.shift();
      if (respawnTimestamps.length > 6) {
        workerPool.splice(pos, 1);
        workerPool.forEach((s, idx) => s.index = idx);
        log('ERR', 'err', `Worker 重複崩潰(30s 內 ${respawnTimestamps.length} 次)— 停止自動重生,請重新整理頁面`);
        if (workerPool.length === 0) {
          instEngine.textContent = 'FAILED';
          instEngine.className = 'inst-val red';
          ledEngine.className = 'inst-led err';
          btnLaunch.disabled = true;
        }
      } else {
        log('SYS', 'dim', `Respawning worker #${pos}...`);
        workerPool[pos] = createWorkerSlot(pos);
      }
      instPoolSize.textContent = `×${workerPool.length}`;
    }
    refreshCapabilityState();
    updateHudQueue();
    drainQueue();
  };

  w.onerror = err => respawn(err.message || 'unknown error');
  w.onmessageerror = () => respawn('message deserialization failed');

  return slot;
}

function initializeWorkerPool() {
  if (workerPool.length) return;
  for (let i = 0; i < maxConcurrent; i++) {
    workerPool.push(createWorkerSlot(i));
  }
  instPoolSize.textContent = `×${workerPool.length}`;
  instConc.textContent = maxConcurrent;
}

function drainQueue() {
  let dispatched = 0;
  while (taskQueue.length > 0) {
    // 計算目前忙碌的 worker 數量(上限 = 記憶體壓力調節後的有效並行數)
    const busyCount = workerPool.filter(s => s.busy).length;
    if (busyCount >= effectiveConcurrent()) break;

    // Find a task/worker pair that satisfies both actual codec capability and
    // the decoded working-set budget. Deferred tasks retain their stable _seq.
    const freeSlots = workerPool.filter(s => !s.busy && s.ready);
    if (!freeSlots.length) break;
    const deferred = [];
    let task = null;
    let freeSlot = null;
    while (taskQueue.length > 0) {
      const candidate = taskQueue.shift();
      const requiredFormat = requiredTaskFormat(candidate);
      if (requiredFormat && readyWorkers === workerPool.length && formatWorkerCapacity(requiredFormat) === 0) {
        failQueuedTask(candidate, `${FMT_LABEL[requiredFormat] || requiredFormat} encoder unavailable in worker pool`);
        continue;
      }
      const candidateSlot = freeSlots.find(slot => slotCanRunTask(slot, candidate));
      if (candidateSlot) {
        task = candidate;
        freeSlot = candidateSlot;
        break;
      }
      deferred.push(candidate);
    }
    deferred.forEach(candidate => taskQueue.push(candidate));
    if (!task || !freeSlot) break;

    freeSlot.busy = true;
    freeSlot.currentTask = task;
    try {
      freeSlot.worker.postMessage(task.msg, task.transfer || []);
    } catch (err) {
      // postMessage 拋出(如攜帶已 detach 的 transferable)不會觸發 worker.onerror,
      // slot 若不還原會永久卡在 busy=true,拖垮有效並行數。
      clearSlotTask(freeSlot);
      failQueuedTask(task, `postMessage failed: ${err.message}`);
      continue;
    }
    dispatched++;
  }
  if (dispatched > 0) updateHudQueue();
}

function onBatchComplete() {
  if (batchCompleted) return; // 冪等防護:避免重複觸發(重試/錯誤路徑競態)
  batchCompleted = true;
  batchRunning = false;
  const totalTime = ((performance.now() - batchStartTime) / 1000).toFixed(1);
  log('OK', 'ok', `Batch complete — ${doneCount} file(s) in ${totalTime}s`);
  btnLaunch.disabled = false;
  updateHudQueue();

  // ══ DOWNLOAD ALL 按鈕發亮提示 ══
  if (results.length > 0) {
    btnDlAll.style.display = 'inline-block';
    btnDlAll.classList.add('glow');
    if (results.length > 2) {
      log('INFO', '', `${results.length} files ready — will be packed as ZIP on download`);
    }
  }

  // ══ DLQ 錯誤報告 ══
  if (deadLetters.length > 0) {
    log('WARN', 'wrn', `${deadLetters.length} file(s) quarantined in Dead Letter Queue — 可匯出錯誤報告`);
    if (btnErrReport) btnErrReport.style.display = 'inline-block';
  }

  // ══ Webhook 自動匯出 ══
  webhook.onBatchComplete(results, deadLetters).catch(err => {
    log('ERR', 'err', `Webhook export failed: ${err.message}`);
  });

  // 批次期間被凍結的即時預覽請求 → 現在補發
  if (preview.master && preview.dirty) preview.schedule();
}


// ══════════════════════════════════════════════════════════
// ── UI 控制 ──────────────────────────────────────────────
// ══════════════════════════════════════════════════════════

const SMART_QUALITY = {
  'image/jpeg': 82,
  'image/png': 100,
  'image/webp': 80,
  'image/avif': 65,
  'image/heif': 75,
  'image/jxl': 100, // 預設走 lossless(封存主力;q<100 = 有損模式)
};

navItems.forEach(item => {
  const open = () => switchView(item.dataset.view);
  item.addEventListener('click', open);
  item.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      open();
    }
  });
});

let changelogTriggerCount = 0;
changelogTrigger?.addEventListener('click', () => {
  changelogTriggerCount++;
  if (changelogTriggerCount < 5) return;
  changelogTriggerCount = 0;
  switchView('changelog');
  document.querySelector('[data-view-panel="changelog"]')?.scrollTo({ top: 0 });
  $('changelogTitle')?.focus({ preventScroll: true });
});

changelogBack?.addEventListener('click', () => {
  changelogTriggerCount = 0;
  switchView('compress');
  changelogTrigger?.focus({ preventScroll: true });
});

document.querySelectorAll('.fmt-chip').forEach(chip => {
  chip.addEventListener('click', () => {
    if (chip.disabled || formatWorkerCapacity(chip.dataset.fmt) === 0) return;
    document.querySelectorAll('.fmt-chip').forEach(c => c.classList.remove('active'));
    chip.classList.add('active');
    selectedFormat = chip.dataset.fmt;
    document.querySelectorAll('.fmt-chip').forEach(c => c.setAttribute('aria-pressed', c === chip ? 'true' : 'false'));
    avifWarn.style.display = selectedFormat === 'image/avif' ? 'block' : 'none';
    heifWarn.style.display = selectedFormat === 'image/heif' ? 'block' : 'none';
    const jxlWarn = $('jxlWarn');
    if (jxlWarn) jxlWarn.style.display = selectedFormat === 'image/jxl' ? 'block' : 'none';

    // HUD：更新格式儀表
    instFmt.textContent = FMT_LABEL[selectedFormat] || '—';
    instFmtSub.textContent = FMT_SUB[selectedFormat] || '';

    // 智慧 Quality 預設
    const smartQ = SMART_QUALITY[selectedFormat];
    if (smartQ !== undefined) {
      qualitySlider.value = smartQ;
    }

    syncQualityUi();
    refreshInfoViews();
    log('INFO', '', `Format → ${FMT_LABEL[selectedFormat]}  (recommended q=${smartQ})`);
  });
});

function syncTimezoneUi() {
  const enabled = tzToggle.checked;
  tzSelect.disabled = !enabled;
  if (tzCard) tzCard.classList.toggle('active', enabled);
}

tzToggle.addEventListener('change', () => {
  syncTimezoneUi();
  refreshInfoViews();
  const status = tzToggle.checked ? `啟用 (${tzSelect.options[tzSelect.selectedIndex].text})` : '停用';
  log('INFO', '', `EXIF 時區覆寫 → ${status}`);
});

tzSelect.addEventListener('change', () => {
  syncTimezoneUi();
  refreshInfoViews();
  log('INFO', '', `EXIF 時區變更 → ${tzSelect.options[tzSelect.selectedIndex].text}`);
});

themeToggle?.addEventListener('change', () => {
  const theme = themeToggle.checked ? 'light' : 'dark';
  applyTheme(theme);
  saveThemePreference(theme);
  log('INFO', '', `介面主題 → ${theme === 'light' ? '淺色模式' : '深色模式'}`);
});

qualitySlider.addEventListener('change', (e) => {
  if (qualitySlider.disabled) return;
  refreshInfoViews();
  log('INFO', '', `品質設定變更 (Quality) → ${e.target.value}/100`);
});

qualitySlider.addEventListener('input', () => {
  if (qualitySlider.disabled) return;
  syncQualityUi();
  refreshInfoViews();
});

// 並發控制
concurrencySelect.addEventListener('change', () => {
  const newMax = parseInt(concurrencySelect.value);
  log('INFO', '', `執行緒設定變更 (Workers & Concurrency) → ${newMax}`);

  maxConcurrent = newMax; // 先更新目標值,maybeShrinkPool 以此為收斂基準
  if (newMax > workerPool.length) {
    // 擴充：產生新的 Worker
    log('SYS', 'dim', `Scaling up worker pool to ${newMax}...`);
    for (let i = workerPool.length; i < newMax; i++) {
      workerPool.push(createWorkerSlot(i));
    }
  } else if (newMax < workerPool.length) {
    // 縮減:砍掉閒置的 Worker;忙碌中的由 clearSlotTask → maybeShrinkPool 於任務結束時補收
    log('SYS', 'dim', `Scaling down worker pool to ${newMax}...`);
    maybeShrinkPool();
    log('OK', 'ok', `Pool shrunk — ${workerPool.length} workers${workerPool.length > newMax ? '(其餘忙碌中,任務完成後回收)' : ' ready'}`);
  }
  instPoolSize.textContent = `×${workerPool.length}`;
  updateConcurrencyHud();
  refreshInfoViews();

  if (workerPool.length > 0 && readyWorkers === workerPool.length && initDone) {
    refreshCapabilityState();
  } else {
    instEngine.textContent = `${readyWorkers}/${workerPool.length}`;
    if (!initDone || readyWorkers < workerPool.length) {
      ledEngine.className = 'inst-led blink';
      btnLaunch.disabled = true;
    }
  }

  drainQueue();
});

// ── File drop ─────────────────────────────────────────────
fileInput.addEventListener('change', () => handleDrop([...fileInput.files]));
resultsGrid.addEventListener('scroll', () => {
  if (results.length > 0) queueResultsRender();
});
new ResizeObserver(() => {
  if (results.length > 0) queueResultsRender();
}).observe(resultsGrid);
uploadZone.addEventListener('dragover', e => { e.preventDefault(); uploadZone.classList.add('drag-over'); });
uploadZone.addEventListener('dragleave', () => uploadZone.classList.remove('drag-over'));
uploadZone.addEventListener('drop', e => {
  e.preventDefault(); uploadZone.classList.remove('drag-over');
  const imgs = [...e.dataTransfer.files].filter(f => {
    if (f.type.startsWith('image/')) return true;
    // Browsers often don't set MIME type for HEIC/HEIF — accept by extension
    const ext = f.name.split('.').pop().toLowerCase();
    return ext === 'heic' || ext === 'heif';
  });
  if (imgs.length) handleDrop(imgs);
});

function handleDrop(files) {
  currentDropToken++;
  pendingFiles = files;
  taskQueue = taskQueue.filter(task => task.msg?.type !== 'EXIF_READ_ONLY');
  preReadFiles.clear();

  refreshInfoViews();
  log('INFO', '', `${files.length} file(s) buffered`);

  // Dispatch EXIF reading tasks immediately
  files.forEach(f => {
    const id = getPreReadId(f);
    preReadFiles.set(id, f);
    taskQueue.push({
      msg: { type: 'EXIF_READ_ONLY', id, file: f, requestToken: currentDropToken },
      transfer: []
    });
  });

  // Side-by-Side 即時預覽 + 檔案大小預估
  preview.setSource(files).catch(err => console.warn('Preview setup failed:', err));
  estimator.refreshBatchEstimate();

  if (workerPool.length > 0 && readyWorkers > 0) {
    // 批次進行中不重新啟用 EXECUTE(見 btnLaunch click handler 註解)——
    // 新拖入的檔案已存入 pendingFiles,目前批次結束後 onBatchComplete 會啟用按鈕。
    if (readyWorkers === workerPool.length && !batchRunning) {
      btnLaunch.disabled = formatWorkerCapacity(selectedFormat) === 0;
    }
    drainQueue(); // Start reading EXIF immediately
  }
}

// ── Execute ───────────────────────────────────────────────
btnLaunch.addEventListener('click', async () => {
  // batchRunning 防重入:沒有此檢查時,批次進行中若有新檔案拖入(或 pool 縮放/
  // worker 重生觸發 READY)會重新啟用按鈕,二次點擊會用新 totalTasks 覆寫計數器,
  // 但舊批次殘留在 taskQueue/taskMap 中的任務仍會繼續完成 → 提前觸發
  // onBatchComplete、doneCount 錯亂、webhook 匯出混雜新舊批次結果。
  if (batchRunning || !pendingFiles.length || readyWorkers < workerPool.length) return;
  const files = [...pendingFiles];
  const format = selectedFormat;
  if (formatWorkerCapacity(format) === 0) {
    log('ERR', 'err', `${FMT_LABEL[format] || format} encoder unavailable; batch not started`);
    refreshCapabilityState();
    return;
  }
  const quality = parseInt(qualitySlider.value);
  const timeShiftMinutes = 0;

  if (tsToggle?.checked && timeShiftMinutes === null) {
    log('ERR', 'err', `時間平移格式無效:「${tsInput?.value}」— 請用 +8、-3:30、+5:45 格式`);
    return;
  }

  btnLaunch.disabled = true;
  batchRunning = true;
  batchCompleted = false;
  deadLetters.length = 0;
  if (btnErrReport) btnErrReport.style.display = 'none';

  closeZoomOverlay();  // 上一批的比對視窗若還開著,先關閉並釋放其 blob URL
  resultsGeneration++; // 讓上一批 in-flight 的 HEIF/JXL 預覽解碼失效(防孤兒 blob URL 洩漏)
  results.forEach(r => {
    URL.revokeObjectURL(r.url);
    if (r.previewUrl && r.previewUrl !== r.url) URL.revokeObjectURL(r.previewUrl);
    if (r.cardEl) r.cardEl._result = null;  // 解除 DOM↔result 的雙向引用,避免殘留卡片洩漏整個 result
    r.cardEl = null;
  });
  results = [];
  heifPreviewQueue.length = 0;
  heifPreviewActive = 0;
  renderedResultIndices.clear();
  totalOrig = totalComp = doneCount = 0;
  totalTasks = files.length;
  batchStartTime = performance.now();
  refreshInfoViews();

  resultsGrid.scrollTop = 0;
  resultsGrid.innerHTML = '';
  // resultsCanvas 是跨批次重用的模組級元素:只清 grid 會把 canvas 連同舊卡片一起拆下,
  // 下一批 ensureResultsCanvas 重掛時舊卡片會跟著回來疊在新卡上(鬼影卡片)
  resultsCanvas.innerHTML = '';
  statsBar.classList.remove('on');
  btnDlAll.style.display = 'none';
  btnDlAll.classList.remove('glow');
  queueResultsRender();

  // HUD 重置
  instDone.textContent = '0';
  instSaved.textContent = '—';

  log('INFO', '', `Compressing ${files.length} file(s)  [${FMT_LABEL[format]} q=${quality}] with ${workerPool.length} workers (max ${maxConcurrent} concurrent)`);
  if (timeShiftMinutes) log('INFO', 'inf', `批次時間平移啟用:所有時間欄位將平移 ${formatShiftLabel(timeShiftMinutes)}`);

  for (const file of files) {
    const id = crypto.randomUUID?.() || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    try {
      const meta = getFileMeta(file);

      addProg(id, file.name, file.size);
      taskMap[id] = {
        file, origSize: file.size,
        startTime: performance.now(),
        processStartTime: null,
        modifyTz: false,
        quality,
        complexity: meta?.complexity ?? null,
        exifMeta: meta,
        exifLogged: false
      };

      const msg = {
        type: 'COMPRESS', id,
        file: file,
        format, quality,
        modifyTz: false,
        tzOffset: null,
        timeShiftMinutes: 0,
      };

      taskQueue.push({ msg });
    } catch (err) {
      log('ERR', 'err', `Cannot read ${file.name}: ${err.message}`);
      recordDeadLetter(file.name, file.size, err.message, 0);
      totalTasks--; // 不做 doneCount++:雙重記帳會虛增完成數
    }
  }

  if (totalTasks <= 0) {
    // 全部檔案入隊即失敗:沒有任何任務會回報完成事件,必須在此收尾,
    // 否則 batchRunning 永久為 true → EXECUTE 鎖死、live preview 凍結整個 session
    log('WARN', 'wrn', '本批次沒有可執行的任務');
    onBatchComplete();
  }

  updateHudQueue();
  drainQueue();
  // Retain pendingFiles so the user can re-compress them by clicking again
  fileInput.value = '';
});


// ══════════════════════════════════════════════════════════
// ── Progress / Results / Terminal ─────────────────────────
// ══════════════════════════════════════════════════════════

function addProg(id, name, size) {
  const wrap = document.createElement('div');
  wrap.id = `prog-${id}`;
  wrap.innerHTML = `
    <div class="log-line">
      <span class="l-ts">${nowStr()}</span>
      <span class="l-tag inf">[PROC]</span>
      <div style="display:flex; justify-content:space-between; width:100%; align-items:baseline;">
        <span class="l-msg dim">${esc(name)} <span style="color:var(--br3);font-size: 10px;margin-left:4px;">${fmtBytes(size)}</span></span>
        <span class="prog-status" id="status-${id}" style="font-family:var(--mono);font-size: 11px;font-weight:600;letter-spacing:1px;color:var(--g);">WAITING...</span>
      </div>
    </div>
    <div class="log-line">
      <div class="prog-row" style="flex:1">
        <div class="prog-track"><div class="prog-fill" id="bar-${id}"></div></div>
      </div>
    </div>`;
  terminal.appendChild(wrap);
  trimTerminal();
  scrollTerm();
}

const STAGE_COLORS = {
  10: '#4fc3f7', // INITIALIZING - light blue
  30: '#00bcd4', // DECODING - cyan
  60: '#00e5ff', // ENCODING - bright cyan
  90: '#1de9b6', // FINALIZING - teal
  100: 'var(--g)' // DONE - theme green
};

function getStageColor(pct) {
  const keys = Object.keys(STAGE_COLORS).map(Number).sort((a,b) => a - b);
  let color = '#4fc3f7';
  for (const k of keys) {
    if (pct >= k) color = STAGE_COLORS[k];
  }
  return color;
}

function updateProg(id, pct, status) {
  const bar = document.getElementById(`bar-${id}`);
  const color = getStageColor(pct);

  if (bar) {
    bar.style.width = pct + '%';
    bar.style.background = color;
    bar.style.boxShadow = `0 0 6px ${color === 'var(--g)' ? 'rgba(0,229,160,0.5)' : color + '80'}`;
  }
  const statusEl = document.getElementById(`status-${id}`);
  if (statusEl && status) {
    statusEl.textContent = `${status} ${pct}%`;
    statusEl.style.color = color;
  }
}

function removeProg(id) {
  const el = document.getElementById(`prog-${id}`);
  if (el) el.remove();
}

async function hydrateHeifPreview(result) {
  const { blob, fileName } = result;
  let bitmap = null;
  let previewUrl = null;
  const targetStage = result.previewTargetStage === 'full' ? 'full' : 'quick';
  const targetWidth = targetStage === 'full' ? HEIF_PREVIEW_FULL_WIDTH : HEIF_PREVIEW_QUICK_WIDTH;
  try {
    if (result.format === 'image/jxl') {
      // JXL:嘗試瀏覽器原生解碼(Safari 17+ 支援;Chromium 會 throw → 標示 failed,
      // 卡片顯示占位圖與說明,檔案本身有效可下載)
      bitmap = await createImageBitmap(blob);
    } else {
      bitmap = await nativeHeifBitmap(blob, targetWidth);
    }
    const previewBlob = await renderBitmapPreviewBlob(bitmap, targetWidth);
    if (result.gen !== resultsGeneration) return; // 批次已重置:孤兒 result,不建 URL(洩漏防護)
    previewUrl = URL.createObjectURL(previewBlob);
    if (result.previewUrl && result.previewUrl !== result.url) {
      URL.revokeObjectURL(result.previewUrl);
    }
    result.previewUrl = previewUrl;
    result.previewState = 'ready';
    result.previewStage = targetStage;
    updateResultCardPreview(result);
    if (targetStage === 'quick' && result.cardEl && result.cardEl.parentNode === resultsCanvas) {
      enqueueHeifPreviewStage(result, (result.previewPriority ?? 0) + 24, 'full');
      flushHeifPreviewQueue();
    }
  } catch (err) {
    console.warn(`HEIF preview decode failed for ${fileName}:`, err);
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    result.previewState = 'failed';
    updateResultCardPreview(result);
  } finally {
    result.previewTargetStage = result.previewStage === 'full' ? 'full' : 'quick';
    if (bitmap && typeof bitmap.close === 'function') {
      bitmap.close();
    }
  }
}

async function renderBitmapPreviewBlob(bitmap, maxWidth) {
  const width = bitmap.width || maxWidth;
  const height = bitmap.height || Math.round(maxWidth * 0.75);
  const scale = width > maxWidth ? maxWidth / width : 1;
  const targetWidth = Math.max(1, Math.round(width * scale));
  const targetHeight = Math.max(1, Math.round(height * scale));

  if (typeof OffscreenCanvas !== 'undefined') {
    const canvas = new OffscreenCanvas(targetWidth, targetHeight);
    const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    ctx.drawImage(bitmap, 0, 0, targetWidth, targetHeight);
    return canvas.convertToBlob({ type: 'image/jpeg', quality: 0.82 });
  }

  const canvas = document.createElement('canvas');
  canvas.width = targetWidth;
  canvas.height = targetHeight;
  const ctx = canvas.getContext('2d', { alpha: false });
  ctx.drawImage(bitmap, 0, 0, targetWidth, targetHeight);
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      canvas.width = 1;
      canvas.height = 1;
      if (blob) {
        resolve(blob);
        return;
      }
      reject(new Error('Preview blob generation failed'));
    }, 'image/jpeg', 0.82);
  });
}

/** 長檔名跑馬燈:必須在卡片掛進 DOM 後量測(detached node 的 scrollWidth/clientWidth 恆為 0) */
function applyMarqueeIfNeeded(card) {
  if (card._marqueeChecked) return;
  card._marqueeChecked = true;
  const nameTrack = card.querySelector('.rc-name-track');
  const nameText = card.querySelector('.rc-name-text');
  if (nameTrack && nameText && nameText.scrollWidth > nameTrack.clientWidth) {
    card.classList.add('has-marquee');
    nameText.style.setProperty('--marquee-distance', `${Math.ceil(nameText.scrollWidth - nameTrack.clientWidth + 18)}px`);
  }
}

function createResultCard(result) {
  if (result.cardEl) {
    updateResultCardPreview(result);
    return result.cardEl;
  }

  const { file, origSize, compSize, fileName, format, ratio, elapsed, timezone, exifMeta, jxlRecovery, metadataStatus } = result;
  const resolvedMeta = mergeExifMeta(exifMeta, { timezone });
  const retained = metadataStatus?.includes('已複製來源 JPEG') === true;
  const dropped = metadataStatus?.includes('不保留') === true;
  const cameraBrand = detectCameraBrand(resolvedMeta.camera);
  const cameraModel = getCameraModel(resolvedMeta.camera);
  const tzLabel = dropped ? '時區未保留' : retained ? (resolvedMeta.timezone ? `UTC ${resolvedMeta.timezone}` : '無時區') : '時區未確認';
  const gpsLabel = dropped ? 'GPS 未保留' : retained ? (resolvedMeta.gps ? 'GPS OK' : '無 GPS') : 'GPS 未確認';
  const cameraLabel = cameraBrand ? `${cameraBrand}` : 'NO CAM';
  const gpsClass = retained && resolvedMeta.gps ? 'ok' : 'dim';
  const tzClass = retained && resolvedMeta.timezone ? 'blue' : 'dim';
  const camClass = cameraBrand ? 'amber' : 'dim';
  const modelLabel = cameraModel || 'Unknown camera model';
  const modelClass = cameraModel ? '' : ' dim';

  const card = document.createElement('div');
  card.className = 'result-card';
  const isAsyncFmt = isAsyncPreviewFormat(format);
  if (!result.url && result.blob) {
    result.url = URL.createObjectURL(result.blob);
    if (!isAsyncFmt) {
      result.previewUrl = result.url;
    }
  }
  const thumbSrc = isAsyncFmt
    ? (result.previewState === 'ready' && result.previewUrl ? result.previewUrl : HEIF_PREVIEW_PLACEHOLDER)
    : result.url;
  card.innerHTML = `
    <img class="rc-thumb" src="${thumbSrc}" alt="${esc(file.name)}" loading="lazy" ${isAsyncFmt ? `data-preview-state="${esc(result.previewState || 'loading')}"` : ''}>
    <div class="rc-name" title="${esc(fileName)}">
      <span class="rc-name-track"><span class="rc-name-text">${esc(fileName)}</span></span>
    </div>
    <div class="rc-camera">
      <span class="rc-chip ${camClass}" title="${esc(resolvedMeta.camera || '未偵測相機品牌')}">${esc(cameraLabel)}</span>
      <div class="rc-model${modelClass}" title="${esc(resolvedMeta.camera || modelLabel)}">${esc(modelLabel)}</div>
    </div>
    <div class="rc-sizes">
      <span class="rc-orig">${fmtBytes(origSize)}</span>
      <span class="rc-arr">→</span>
      <span class="rc-new">${fmtBytes(compSize)}</span>
      <span class="rc-inline-meta">
        <span class="rc-ratio">${ratio >= 0 ? '-' : '+'}${Math.abs(ratio)}%</span>
        <span class="rc-time">${elapsed}s</span>
      </span>
    </div>
    <div class="rc-foot">
      <div class="rc-foot-meta">
        ${jxlRecovery ? '<span class="rc-chip amber" title="原本要求 JXL quality 100 像素無損，但 libjxl 無損編碼中止；此檔已用 quality 99 近無損輸出。">JXL 99 · NEAR-LOSSLESS</span>' : ''}
        <span class="rc-chip ${metadataStatus?.includes('已複製來源 JPEG') ? 'ok' : 'amber'}" title="${esc(metadataStatus || '中繼資料狀態未知')}">${metadataStatus?.includes('已複製來源 JPEG') ? '中繼資料已複製' : metadataStatus?.includes('不保留') ? '中繼資料未保留' : '中繼資料需核對'}</span>
        <span class="rc-chip ${tzClass}" title="${esc(resolvedMeta.timezone || '未偵測時區')}">${esc(tzLabel)}</span>
        <span class="rc-chip ${gpsClass}" title="${esc(resolvedMeta.gps || '無 GPS 資訊')}">${esc(gpsLabel)}</span>
      </div>
      <div class="rc-fmt">${(EXT_MAP[format] || 'bin').toUpperCase()}</div>
    </div>
    <a class="btn-dl" href="${result.url}" download="${esc(fileName)}">↓ DOWNLOAD</a>`;
  const thumb = card.querySelector('.rc-thumb');
  if (thumb && isAsyncPreviewFormat(format)) {
    updateResultCardPreview(result);
  }
  card._result = result;
  result.cardEl = card;
  return card;
}

function addResultCard(result) {
  results.push(result);
  queueResultsRender();
}

function updateStats() {
  statsBar.classList.add('on');
  // btnDlAll 只由 onBatchComplete 顯示:批次進行中出現會讓使用者拿到不完整的 ZIP
  $('statFiles').textContent = doneCount;
  $('statOrig').textContent = fmtBytes(totalOrig);
  $('statComp').textContent = fmtBytes(totalComp);

  const delta = totalOrig - totalComp;
  const absDelta = Math.abs(delta);
  const deltaEl = $('statDelta');
  const deltaLb = $('statDeltaLb');

  if (totalOrig > 0) {
    deltaEl.textContent = (delta >= 0 ? '-' : '+') + fmtBytes(absDelta);
    deltaEl.style.color = delta >= 0 ? 'var(--g)' : 'var(--amb)';
    deltaLb.textContent = delta >= 0 ? 'DATA_REDUCED' : 'CAPACITY_OVER';
    deltaLb.style.color = delta >= 0 ? 'var(--g)' : 'var(--amb)';
  } else {
    deltaEl.textContent = '—';
    deltaLb.textContent = 'PENDING';
  }

  const ratio = totalOrig > 0 ? (1 - totalComp / totalOrig) : 0;
  const pct = (ratio * 100).toFixed(1) + '%';
  const displayPct = ratio >= 0 ? pct : `+${Math.abs(ratio * 100).toFixed(1)}%`;

  const savedEl = $('statSaved');
  const statusEl = $('statStatus');

  savedEl.textContent = displayPct;

  if (totalOrig > 0) {
    if (ratio >= 0) {
      savedEl.style.color = 'var(--g)';
      statusEl.textContent = 'OPTIMAL_RATIO';
      statusEl.style.color = 'var(--g)';
    } else {
      savedEl.style.color = 'var(--amb)';
      statusEl.textContent = 'EFFICIENCY_DROP';
      statusEl.style.color = 'var(--amb)';
    }
  } else {
    statusEl.textContent = 'CORE_IDLE';
  }
}

window.downloadAll = async () => {
  btnDlAll.classList.remove('glow');

  if (results.length > 1) {
    // ══ 超過 1 張：打包 ZIP 下載 ══
    if (typeof window.JSZip !== 'function') {
      zipReady = false;
      refreshCapabilityState();
      log('ERR', 'err', 'ZIP 引擎不可用；結果仍保留，可逐檔重新處理或重新整理後再試');
      return;
    }
    log('SYS', 'inf', `正在將 ${results.length} 個檔案打包成 ZIP...`);
    const zip = new window.JSZip();
    // 同名輸出去重:a.heic + a.png 轉 JPEG 會都變成 a.jpg,JSZip 同名 file() 會靜默覆蓋(丟檔)。
    // 用不分大小寫比對:大小寫不敏感的檔案系統(macOS/Windows)解壓時同樣會互相覆蓋。
    const usedNames = new Set();
    let renamed = 0;
    for (const { fileName, blob } of results) {
      const dot = fileName.lastIndexOf('.');
      const base = dot === -1 ? fileName : fileName.slice(0, dot);
      const ext = dot === -1 ? '' : fileName.slice(dot);
      let name = fileName;
      for (let i = 1; usedNames.has(name.toLowerCase()); i++) name = `${base} (${i})${ext}`;
      if (name !== fileName) renamed++;
      usedNames.add(name.toLowerCase());
      zip.file(name, blob);
    }
    if (renamed) log('WARN', 'wrn', `${renamed} 個同名輸出已自動加序號,避免在 ZIP 內互相覆蓋`);
    // streamFiles:逐檔串流寫入,大批次打包時的峰值記憶體大幅降低
    let zipBlob;
    try {
      // streamFiles bounds per-entry staging, but browser Blob output still
      // materializes one complete final ZIP. Keep that peak explicit and loud.
      zipBlob = await zip.generateAsync({ type: 'blob', streamFiles: true });
    } catch (err) {
      log('ERR', 'err', `ZIP 打包失敗: ${err.message || err}`);
      return;
    }
    const zipUrl = URL.createObjectURL(zipBlob);
    const now = new Date();
    const ts = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}_${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}`;
    const zipName = `SYS_COMPRESS_${ts}.zip`;
    Object.assign(document.createElement('a'), { href: zipUrl, download: zipName }).click();
    log('OK', 'ok', `ZIP 打包完成: ${zipName} (${fmtBytes(zipBlob.size)})`);
    setTimeout(() => URL.revokeObjectURL(zipUrl), 5000);
  } else if (results.length === 1) {
    // ══ 1 張：直接下載(不需批次間的 200ms 間隔延遲)══
    // url 可能因卡片滾出視口被 revoke → 以保留的 blob 現建一個臨時 URL 兜底。
    const only = results[0];
    const href = only.url || (only.blob ? URL.createObjectURL(only.blob) : null);
    if (href) {
      Object.assign(document.createElement('a'), { href, download: only.fileName }).click();
      if (href !== only.url) setTimeout(() => URL.revokeObjectURL(href), 5000);
    }
  }
};

// ── Terminal logging ──
function log(tag, cls, msg) {
  const paddedTag = tag.padEnd(4, ' ');
  console.log(`[${paddedTag}] ${msg}`);
  const tagClass = { SYS: 'sys', OK: 'ok', INFO: 'inf', WARN: 'wrn', ERR: 'err', PROC: 'inf' }[tag] || 'sys';
  const line = document.createElement('div');
  line.className = 'log-line';
  line.innerHTML = `
    <span class="l-ts">${nowStr()}</span>
    <span class="l-tag ${tagClass}">[${paddedTag}]</span>
    <span class="l-msg ${cls}">${esc(msg)}</span>`;
  terminal.appendChild(line);
  trimTerminal();
  scrollTerm();
}

window.clearLog = () => { terminal.innerHTML = ''; log('SYS', 'dim', 'Log cleared'); };
// 終端頂層節點上限:結果區有虛擬清單回收,終端沒有 —
// 大批次(500+ 檔)時無上限的 log DOM 會拖垮整頁排版效能
const TERMINAL_MAX_NODES = 500;
function trimTerminal() {
  while (terminal.childElementCount > TERMINAL_MAX_NODES) terminal.firstElementChild.remove();
}
function scrollTerm() { terminal.scrollTop = terminal.scrollHeight; }
function nowStr() { return new Date().toTimeString().slice(0, 8); }
function fmtBytes(b) {
  if (b == null || !Number.isFinite(b)) return '—';
  if (b < 1024) return `${b} B`;
  if (b < 1048576) return `${(b / 1024).toFixed(1)} KB`;
  return `${(b / 1048576).toFixed(2)} MB`;
}
function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// ══════════════════════════════════════════════════════════
// ── 批次時間平移(Batch Time Shift)輸入解析 ────────────────
// 接受:"+8"、"-3"、"+3.5"、"-3:30"、"+5:45" → 回傳分鐘數(整數)或 null(無效)
// ══════════════════════════════════════════════════════════

function parseTimeShiftInput(raw) {
  if (raw == null) return null;
  const str = String(raw).trim();
  if (!str) return null;
  let m = /^([+-]?)(\d{1,3}):([0-5]\d)$/.exec(str);       // ±HH:MM
  if (m) {
    const minutes = (+m[2]) * 60 + (+m[3]);
    return m[1] === '-' ? -minutes : minutes;
  }
  m = /^([+-]?)(\d{1,3})(?:\.(\d+))?$/.exec(str);          // ±H 或 ±H.5
  if (m) {
    const minutes = Math.round(((+m[2]) + (m[3] ? +(`0.${m[3]}`) : 0)) * 60);
    return m[1] === '-' ? -minutes : minutes;
  }
  return null;
}

function formatShiftLabel(minutes) {
  const abs = Math.abs(minutes);
  const h = Math.floor(abs / 60), mm = abs % 60;
  return `${minutes < 0 ? '-' : '+'}${h}h${mm ? String(mm).padStart(2, '0') + 'm' : ''}`;
}

function syncTimeShiftUi() {
  if (!tsToggle) return;
  const enabled = tsToggle.checked;
  if (tsInput) tsInput.disabled = !enabled;
  if (tsCard) tsCard.classList.toggle('active', enabled);
  if (tsHint && enabled) {
    const parsed = parseTimeShiftInput(tsInput?.value);
    tsHint.textContent = parsed === null
      ? '⚠ 格式無效 — 用 +8、-3:30 或 +5:45'
      : `所有時間欄位將平移 ${formatShiftLabel(parsed)}(GPS 時間不動:衛星時間本來就正確)`;
    tsHint.classList.toggle('err', parsed === null);
  } else if (tsHint) {
    tsHint.textContent = '平移 DateTime / DateTimeOriginal / DateTimeDigitized(EXIF 2.32)';
    tsHint.classList.remove('err');
  }
}

tsToggle?.addEventListener('change', () => {
  syncTimeShiftUi();
  refreshInfoViews();
  log('INFO', '', `批次時間平移 → ${tsToggle.checked ? `啟用 (${tsInput?.value || '+0'})` : '停用'}`);
});
tsInput?.addEventListener('input', () => { syncTimeShiftUi(); refreshInfoViews(); });

// ══════════════════════════════════════════════════════════
// ── AI 檔案大小預估引擎(Estimation Engine)────────────────
// 三層模型:
//   1. 解析式基準曲線(每格式的 bpp-quality 冪次曲線 × 複雜度係數)
//   2. 色彩複雜度取樣(預覽圖平均梯度 → 0~1)
//   3. 歷史校準(localStorage 保存實際壓縮 bpp,K 近鄰加權混合)
// ══════════════════════════════════════════════════════════

const estimator = {
  HISTORY_KEY: 'nexpress-esthist-v3',
  MAX_HISTORY: 240,
  history: [],
  cropCalibration: null,    // { file, cropBpp, format, quality } — 300×300 crop 實測 bpp
  _refreshTimer: null,

  load() {
    try {
      const raw = localStorage.getItem(this.HISTORY_KEY);
      if (raw) this.history = JSON.parse(raw).filter(e => Number.isFinite(e?.bpp) && e.bpp > 0);
    } catch { this.history = []; }
  },
  save() {
    try { localStorage.setItem(this.HISTORY_KEY, JSON.stringify(this.history.slice(-this.MAX_HISTORY))); } catch {}
  },

  /** 解析式基準:bits per pixel(complexity c ∈ 0~1,預設 0.5) */
  baseBpp(format, quality, c = 0.5) {
    const q = Math.min(Math.max(quality, 1), 100) / 100;
    const cf = 0.45 + 1.1 * c;                       // 複雜度係數
    const jpegBpp = (0.35 + 3.0 * Math.pow(q, 2.6)) * cf;
    switch (format) {
      case 'image/jpeg': return jpegBpp;
      case 'image/webp': return jpegBpp * 0.78;
      case 'image/avif': return jpegBpp * 0.55;
      case 'image/jxl':  return quality >= 100 ? (3.5 + 9 * c) : jpegBpp * 0.7;
      case 'image/png':  return 5 + 14 * c;          // 無損:幾乎只看複雜度
      case 'image/heif': return jpegBpp * 0.6; // 原生 HEVC，之後由樣本與實測校準
      default: return jpegBpp;
    }
  },

  /** 歷史校準預測:同格式 K 近鄰(quality±12、complexity 距離加權)混合解析曲線 */
  predictBpp(format, quality, c = 0.5) {
    const analytic = this.baseBpp(format, quality, c);
    const candidates = this.history.filter(e => e.f === format && Math.abs(e.q - quality) <= 12);
    if (!candidates.length) return analytic;
    let wSum = 0, bppSum = 0;
    for (const e of candidates) {
      const w = 1 / (0.05 + Math.abs(e.q - quality) / 12 + Math.abs((e.c ?? 0.5) - c));
      wSum += w; bppSum += e.bpp * w;
    }
    const learned = bppSum / wSum;
    // 一筆真實結果就開始提供校準，但資料少時仍以解析模型為主；
    // 同時雙向限制異常歷史值，避免單一極端圖片污染後續估算。
    const learnedWeight = Math.min(0.65, 0.25 + (candidates.length - 1) * 0.15);
    const bounded = Math.min(analytic * 2, Math.max(analytic * 0.35, learned));
    return analytic * (1 - learnedWeight) + bounded * learnedWeight;
  },

  recordActual(format, quality, complexity, bytes, pixels) {
    if (!pixels || !bytes) return;
    const bpp = (bytes * 8) / pixels;
    if (!Number.isFinite(bpp) || bpp <= 0 || bpp > 64) return;
    this.history.push({ f: format, q: quality, c: complexity ?? 0.5, bpp });
    if (this.history.length > this.MAX_HISTORY) this.history = this.history.slice(-this.MAX_HISTORY);
    this.save();
  },

  /**
   * 單檔預估與不確定範圍。Live Preview 是縮放後的中央樣本，不是完整影像，
   * 因此只能作為校準訊號，不能再完全覆蓋解析／歷史模型。
   */
  estimateFile(file, format, quality) {
    const meta = getFileMeta(file);
    const c = meta?.complexity ?? 0.5;
    let pixels = (meta?.width && meta?.height) ? meta.width * meta.height : null;
    if (!pixels) {
      // 回推:JPEG 來源平均 ~4.0bpp(高品質)、PNG ~12bpp、HEIC ~1.6bpp
      // 注意:原本 2.2bpp 假設太低,高品質 JPEG 實際可達 6-8bpp,
      // 導致像素數被嚴重高估 → 預估體積膨脹 2-3 倍。提高到 4.0 取平衡值。
      const n = file.name.toLowerCase();
      const srcBpp = /\.png$/.test(n) ? 12
        : /\.hei[cf]$/.test(n) ? 1.6
        : /\.avif$/.test(n) ? 1.2   // AVIF 來源壓縮率高:沿用 4.0 會把像素數低估 3-4 倍
        : /\.webp$/.test(n) ? 2.5
        : 4.0;
      pixels = Math.min((file.size * 8) / srcBpp, 120_000_000);
    }
    const modelBpp = this.predictBpp(format, quality, c);
    let bpp = modelBpp;
    let sampleBpp = null;
    // 舊模型使用 -0.3 次方並完全取代解析模型，會把 20MP 級照片低估到
    // 真實大小的一半以下。改用較保守的 -0.14 次方，且以 75/25 混合
    // 樣本與解析／歷史模型；樣本異常時限制在模型的 0.5～2 倍。
    if (this.cropCalibration && this.cropCalibration.file === file &&
        this.cropCalibration.format === format &&
        this.cropCalibration.quality === quality && pixels > 0) {
      const cropPixels = PREVIEW_SIZE * PREVIEW_SIZE;
      const resolutionScale = Math.min(1, Math.max(0.35, Math.pow(cropPixels / pixels, 0.14)));
      const extrapolated = this.cropCalibration.cropBpp * resolutionScale;
      sampleBpp = Math.min(modelBpp * 2, Math.max(modelBpp * 0.5, extrapolated));
      bpp = modelBpp * 0.25 + sampleBpp * 0.75;
    }
    const bytes = Math.max(1024, Math.round(pixels * bpp / 8));
    const uncertainty = sampleBpp === null ? 0.32 : 0.22;
    // JPEG 最終路徑會重新注入 EXIF/ICC，而快速預覽樣本不含這些區段；
    // 將可能的 metadata 成本放入上界，不假裝點估計能精確預知它。
    const metadataHeadroom = format === 'image/jpeg'
      ? Math.min(256 * 1024, Math.max(2048, Math.round(file.size * 0.03)))
      : 0;
    const lowBytes = Math.max(1024, Math.round(bytes * (1 - uncertainty)));
    const highBytes = Math.max(lowBytes, Math.round(bytes * (1 + uncertainty) + metadataHeadroom));
    return { bytes, lowBytes, highBytes, modelBpp, sampleBpp };
  },

  estimateFileBytes(file, format, quality) {
    return this.estimateFile(file, format, quality).bytes;
  },

  formatReductionRange(inputBytes, lowBytes, highBytes) {
    if (!inputBytes) return '';
    const best = (1 - lowBytes / inputBytes) * 100;
    const worst = (1 - highBytes / inputBytes) * 100;
    if (worst >= 0) return `預估縮減 ${worst.toFixed(0)}–${best.toFixed(0)}%`;
    if (best <= 0) return `預估增加 ${Math.abs(best).toFixed(0)}–${Math.abs(worst).toFixed(0)}%`;
    return `可能介於增加 ${Math.abs(worst).toFixed(0)}% 與縮減 ${best.toFixed(0)}%`;
  },

  /** 批次總預估 → BATCH 面板 + 預覽面板(150ms throttle) */
  refreshBatchEstimate(force = false) {
    if (force && this._refreshTimer) {
      clearTimeout(this._refreshTimer);
      this._refreshTimer = null;
    }
    if (this._refreshTimer) return;
    this._refreshTimer = setTimeout(() => {
      this._refreshTimer = null;
      if (!pendingFiles.length) {
        if (batchEstimateStat) batchEstimateStat.textContent = '—';
        if (batchEstimateCopy) batchEstimateCopy.textContent = '拖入圖片後,這裡會即時預估壓縮後的總體積(依複雜度取樣與歷史數據校準)。';
        if (pvEst) pvEst.textContent = '';
        return;
      }
      const quality = parseInt(qualitySlider.value, 10) || 82;
      let totalIn = 0, totalLow = 0, totalHigh = 0;
      for (const f of pendingFiles) {
        totalIn += f.size;
        const estimate = this.estimateFile(f, selectedFormat, quality);
        totalLow += estimate.lowBytes;
        totalHigh += estimate.highBytes;
      }
      const rangeLabel = `${fmtBytes(totalLow)}–${fmtBytes(totalHigh)}`;
      const reductionLabel = this.formatReductionRange(totalIn, totalLow, totalHigh);
      if (batchEstimateStat) batchEstimateStat.textContent = `≈ ${rangeLabel}`;
      if (batchEstimateCopy) {
        batchEstimateCopy.textContent = `${pendingFiles.length} 檔輸入 ${fmtBytes(totalIn)} → 預估輸出範圍 ${rangeLabel}` +
          `（${reductionLabel}）。` +
          ` 模型:解析曲線 × 複雜度取樣 × ${this.history.length} 筆歷史校準。`;
      }
      if (pvEst) {
        pvEst.textContent = `EST RANGE: ${fmtBytes(totalIn)} → ≈ ${rangeLabel}（${reductionLabel}）`;
      }
    }, 150);
  },
};
estimator.load();

/** 從 300×300 ImageData 計算色彩複雜度(平均亮度梯度 → 0~1) */
function computeComplexity(imageData) {
  const { data, width, height } = imageData;
  let sum = 0, n = 0;
  const stride = 4;
  for (let y = 0; y < height - 2; y += 2) {          // 隔行取樣減半成本
    for (let x = 0; x < width - 2; x += 2) {
      const i = (y * width + x) * stride;
      const lum = data[i] * 0.299 + data[i + 1] * 0.587 + data[i + 2] * 0.114;
      const iR = i + stride * 2;
      const iD = i + width * stride * 2;
      const lumR = data[iR] * 0.299 + data[iR + 1] * 0.587 + data[iR + 2] * 0.114;
      const lumD = data[iD] * 0.299 + data[iD + 1] * 0.587 + data[iD + 2] * 0.114;
      sum += Math.abs(lum - lumR) + Math.abs(lum - lumD);
      n += 2;
    }
  }
  if (!n) return 0.5;
  return Math.min(1, Math.max(0.05, (sum / n) / 40));
}

// ══════════════════════════════════════════════════════════
// ── Side-by-Side 局部即時預覽(300×300 中央裁切)────────────
// 拖動 Quality 滑桿 → 只編碼中央 300×300 → canvas 即時比對。
// inflight + dirty 旗標:永遠只有一個未完成請求,回覆過時即丟棄。
// ══════════════════════════════════════════════════════════

const PREVIEW_SIZE = 300;

const preview = {
  master: null,          // 300×300 ImageData(裁切母本)
  sourceFile: null,
  sourceGeneration: 0,
  token: 0,
  inflightId: null,
  dirty: false,
  sentFormat: null,
  sentQuality: null,

  async setSource(files) {
    const generation = ++this.sourceGeneration;
    const eligible = files.find(f => {
      const t = (f.type || '').toLowerCase();
      if (['image/jpeg', 'image/png', 'image/webp', 'image/avif'].includes(t)) return true;
      return /\.(jpe?g|png|webp|avif)$/i.test(f.name);
    });
    if (!eligible || eligible.size > 80_000_000) {
      this.master = null;
      this.sourceFile = null;
      estimator.cropCalibration = null;  // 校準值只對剛才那張裁切樣本有效,清掉避免套用到下一批不相關檔案
      taskQueue = taskQueue.filter(t => t.msg?.type !== 'PREVIEW_ENCODE'); // 撤下佇列中未派工的舊預覽任務
      this.inflightId = null;
      if (previewSec) previewSec.style.display = 'none';
      return;
    }
    if (this.sourceFile === eligible && this.master) { this.schedule(); return; }
    this.sourceFile = eligible;
    estimator.cropCalibration = null;  // 換了新的裁切樣本 → 舊校準值不再適用,等下一次 handleDone 重新計算
    // 撤下仍在佇列、尚未派工的舊預覽任務:光靠 inflightId 歸零只會讓回覆被丟棄,
    // worker 仍會白編碼一次;快速連續換檔會堆出一串殭屍任務
    taskQueue = taskQueue.filter(t => t.msg?.type !== 'PREVIEW_ENCODE');
    this.inflightId = null;            // 讓舊圖 in-flight 的回覆失效,避免它把錯亂的校正值寫回來

    let bitmap = null;
    try {
      bitmap = /\.(heic|heif)$/i.test(eligible.name) || /^image\/hei[cf]$/i.test(eligible.type)
        ? await nativeHeifBitmap(eligible, PREVIEW_SIZE * 4)
        : await createImageBitmap(eligible);
      if (generation !== this.sourceGeneration || this.sourceFile !== eligible) return;
      const side = Math.min(bitmap.width, bitmap.height, PREVIEW_SIZE * 4);
      const sx = Math.max(0, (bitmap.width - side) / 2);
      const sy = Math.max(0, (bitmap.height - side) / 2);
      const canvas = new OffscreenCanvas(PREVIEW_SIZE, PREVIEW_SIZE);
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(bitmap, sx, sy, side, side, 0, 0, PREVIEW_SIZE, PREVIEW_SIZE);
      this.master = ctx.getImageData(0, 0, PREVIEW_SIZE, PREVIEW_SIZE);

      // 複雜度取樣 + 真實像素尺寸 → 餵給預估引擎(免去用檔案大小回推像素的誤差)
      const complexity = computeComplexity(this.master);
      setFileMeta(eligible, mergeExifMeta(getFileMeta(eligible), { complexity, width: bitmap.width, height: bitmap.height }));
      estimator.refreshBatchEstimate();

      // 左側:原圖裁切
      if (pvOrig) {
        const octx = pvOrig.getContext('2d');
        octx.putImageData(this.master, 0, 0);
      }
      if (previewSec) previewSec.style.display = '';
      if (pvMeta) pvMeta.textContent = `SOURCE: ${eligible.name} 中央 ${PREVIEW_SIZE}×${PREVIEW_SIZE}`;
      this.schedule();
    } catch (err) {
      if (generation !== this.sourceGeneration) return;
      console.warn('Preview source decode failed:', err);
      this.master = null;
      if (previewSec) previewSec.style.display = 'none';
    } finally {
      bitmap?.close?.();
    }
  },

  schedule() {
    if (!this.master || !initDone) return;
    if (batchRunning) { this.dirty = true; return; } // 批次進行中不搶 worker
    if (this.inflightId) { this.dirty = true; return; }
    this._send();
  },

  _send() {
    this.dirty = false;
    this.token++;
    const id = `pv:${this.token}`;
    this.inflightId = id;
    const rgba = this.master.data.slice().buffer;    // 每次傳送都複製(transfer 會奪走)
    const format = selectedFormat;
    const quality = parseInt(qualitySlider.value, 10) || 82;
    // 記錄這次請求實際送出的 format/quality;handleDone 必須用這組而非
    // 屆時的即時 UI 狀態,否則 inflight 期間使用者切換格式/品質會讓回覆
    // 被記到錯誤的 (format, quality) 校準鍵下。
    this.sentFormat = format;
    this.sentQuality = quality;
    taskQueue.push({
      msg: { type: 'PREVIEW_ENCODE', id, rgba, width: PREVIEW_SIZE, height: PREVIEW_SIZE, format, quality },
      transfer: [rgba],
      priority: PRIORITY.PREVIEW,
    });
    drainQueue();
  },

  async handleDone(data) {
    if (data.id !== this.inflightId) return;         // 過時回覆:丟棄
    const sourceGeneration = this.sourceGeneration;
    this.inflightId = null;
    const size = data.buffer.byteLength;
    const sentFormat = this.sentFormat;
    const sentQuality = this.sentQuality;
    const qLabel = sentQuality;
    // ── Crop-based calibration: 記下 300×300 實測 bpp,估算時依解析度外插 ──
    // 扣掉固定容器開銷(標頭/量化表約 700B,對 90k 像素的小圖占比不小)
    const cropPixels = PREVIEW_SIZE * PREVIEW_SIZE;  // 90000
    const CROP_CONTAINER_OVERHEAD = 700;
    const actualCropBpp = (Math.max(0, size - CROP_CONTAINER_OVERHEAD) * 8) / cropPixels;
    if (Number.isFinite(actualCropBpp) && actualCropBpp > 0) {
      estimator.cropCalibration = {
        file: this.sourceFile,
        cropBpp: actualCropBpp,
        format: sentFormat,
        quality: sentQuality,
      };
    }
    // 同步更新 EST RANGE 面板（force=true 跳過 throttle）
    estimator.refreshBatchEstimate(true);
    if (pvMeta) {
      pvMeta.textContent = `SAMPLE: 中央區域縮放至 300² → ${fmtBytes(size)} @ q${qLabel} · ${data.ms}ms｜輸出範圍見上方`;
    }
    try {
      const blob = new Blob([data.buffer], { type: data.format });
      const bitmap = sentFormat === 'image/heif'
        ? await nativeHeifBitmap(blob, PREVIEW_SIZE)
        : await createImageBitmap(blob);
      if (sourceGeneration !== this.sourceGeneration) {
        bitmap.close?.();
        return;
      }
      if (pvComp) {
        const ctx = pvComp.getContext('2d');
        ctx.clearRect(0, 0, PREVIEW_SIZE, PREVIEW_SIZE);
        ctx.drawImage(bitmap, 0, 0, PREVIEW_SIZE, PREVIEW_SIZE);
      }
      bitmap.close?.();
    } catch {
      // JXL 或 HEIF 預覽解碼失敗時，改顯示大小資訊。
      if (pvComp) {
        const ctx = pvComp.getContext('2d');
        ctx.clearRect(0, 0, PREVIEW_SIZE, PREVIEW_SIZE);
        ctx.fillStyle = 'rgba(77,159,255,0.12)';
        ctx.fillRect(0, 0, PREVIEW_SIZE, PREVIEW_SIZE);
        ctx.fillStyle = '#6a8aaa';
        ctx.font = '11px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('此格式無法原生預覽', PREVIEW_SIZE / 2, PREVIEW_SIZE / 2 - 8);
        ctx.fillText(`輸出 ≈ ${fmtBytes(size)}`, PREVIEW_SIZE / 2, PREVIEW_SIZE / 2 + 10);
      }
    }
    if (this.dirty) this._send();                    // 期間滑桿又動過 → 立刻補發
  },

  handleError(data) {
    if (data.id !== this.inflightId) return;
    this.inflightId = null;
    if (pvMeta) pvMeta.textContent = `預覽編碼失敗:${data.error}`;
    if (this.dirty) this._send();
  },
};

function handlePreviewDone(data) { preview.handleDone(data); }
function handlePreviewError(data) { preview.handleError(data); }

qualitySlider.addEventListener('input', () => {
  if (!qualitySlider.disabled) {
    preview.schedule();
    estimator.refreshBatchEstimate();
  }
});
document.querySelectorAll('.fmt-chip').forEach(chip => {
  chip.addEventListener('click', () => {
    preview.schedule();
    estimator.refreshBatchEstimate();
  });
});

// ══════════════════════════════════════════════════════════
// ── Webhook / API 自動匯出模組 ─────────────────────────────
// 批次完成後將輸出檔 + metadata JSON 以 multipart POST 拋送自建伺服器。
// 隱私原則:預設關閉;唯有使用者主動設定 URL 並開啟才會有任何網路傳輸。
// ══════════════════════════════════════════════════════════

const webhook = {
  KEY: 'nexpress-webhook-v1',
  cfg: { enabled: false, url: '', token: '' },

  load() {
    try {
      const raw = localStorage.getItem(this.KEY);
      if (raw) {
        const stored = JSON.parse(raw);
        // Tokens are session-only. Reading and immediately dropping a legacy
        // persisted token migrates older installations without retaining it.
        this.cfg = { ...this.cfg, enabled: Boolean(stored.enabled), url: String(stored.url || '') };
        if (Object.prototype.hasOwnProperty.call(stored, 'token')) this.save();
      }
    } catch {}
  },
  save() {
    try { localStorage.setItem(this.KEY, JSON.stringify({ enabled: this.cfg.enabled, url: this.cfg.url })); } catch {}
  },
  validUrl(u) {
    try {
      const url = new URL(u);
      return url.protocol === 'https:' ||
        (url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname));
    } catch { return false; }
  },
  headers(token = this.cfg.token) {
    const h = {};
    if (token) h['Authorization'] = `Bearer ${token}`;
    return h;
  },
  setStatus(text, cls = '') {
    if (whStatus) { whStatus.textContent = text; whStatus.className = `wh-status ${cls}`; }
  },

  async _fetch(body, requestConfig, extraHeaders = {}, timeoutMs = 20000) {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    try {
      const res = await fetch(requestConfig.url, {
        method: 'POST',
        body,
        headers: { ...this.headers(requestConfig.token), ...extraHeaders },
        signal: ac.signal,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res;
    } finally {
      clearTimeout(timer);
    }
  },

  async sendResult(result, batchId, requestConfig, attempt = 1) {
    const fd = new FormData();
    fd.append('file', result.blob, result.fileName);
    fd.append('metadata', new Blob([JSON.stringify({
      app: 'NEXPRESS', version: APP_VERSION, type: 'file', batchId,
      fileName: result.fileName,
      sourceName: result.file?.name ?? null,
      origSize: result.origSize, compSize: result.compSize,
      ratio: Number(result.ratio), format: result.format,
      elapsedSec: Number(result.elapsed),
      timezone: result.metadataStatus?.includes('已複製來源 JPEG') ? (result.timezone ?? null) : null,
      timeShiftMinutes: result.timeShift ?? null,
      metadataStatus: result.metadataStatus ?? '未確認',
      exif: result.exifMeta ?? null,
    })], { type: 'application/json' }), 'metadata.json');
    try {
      await this._fetch(fd, requestConfig, { 'X-Nexpress-Batch': batchId });
      return true;
    } catch (err) {
      if (attempt < 3) {
        await new Promise(r => setTimeout(r, attempt * 1500)); // 線性退避重試
        return this.sendResult(result, batchId, requestConfig, attempt + 1);
      }
      log('ERR', 'err', `Webhook: ${result.fileName} 傳送失敗(${err.message},已重試 ${attempt - 1} 次)`);
      return false;
    }
  },

  async onBatchComplete(batchResults, dlq) {
    if (!this.cfg.enabled || !this.validUrl(this.cfg.url) || !batchResults.length) return;
    const requestConfig = Object.freeze({ url: this.cfg.url, token: this.cfg.token });
    const resultSnapshot = [...batchResults];
    const dlqSnapshot = dlq.map(entry => ({ ...entry }));
    const batchId = `batch_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`;
    log('INFO', 'inf', `Webhook 匯出開始 → ${requestConfig.url}(${resultSnapshot.length} 檔,batch ${batchId})`);
    this.setStatus('EXPORTING...', 'busy');

    let ok = 0, fail = 0;
    const queue = [...resultSnapshot];
    const workers = Array.from({ length: 2 }, async () => {   // 並發 2,避免壓垮對端
      while (queue.length) {
        const r = queue.shift();
        (await this.sendResult(r, batchId, requestConfig)) ? ok++ : fail++;
      }
    });
    await Promise.all(workers);

    // 批次摘要(JSON)
    try {
      await this._fetch(JSON.stringify({
        app: 'NEXPRESS', version: APP_VERSION, type: 'batch_summary', batchId,
        when: new Date().toISOString(),
        totals: { files: resultSnapshot.length, sent: ok, failed: fail },
        deadLetters: dlqSnapshot,
      }), requestConfig, { 'Content-Type': 'application/json', 'X-Nexpress-Batch': batchId });
    } catch (err) {
      log('WARN', 'wrn', `Webhook 摘要傳送失敗:${err.message}`);
    }

    log(fail ? 'WARN' : 'OK', fail ? 'wrn' : 'ok', `Webhook 匯出完成:${ok} 成功 / ${fail} 失敗`);
    this.setStatus(fail ? `DONE (${fail} FAILED)` : 'DONE', fail ? 'err' : 'ok');
  },

  async test() {
    if (!this.validUrl(this.cfg.url)) { this.setStatus('INVALID URL', 'err'); return; }
    const requestConfig = Object.freeze({ url: this.cfg.url, token: this.cfg.token });
    this.setStatus('TESTING...', 'busy');
    try {
      await this._fetch(JSON.stringify({
        app: 'NEXPRESS', version: APP_VERSION, type: 'test', when: new Date().toISOString(),
      }), requestConfig, { 'Content-Type': 'application/json' }, 8000);
      this.setStatus('CONNECTED ✓', 'ok');
      log('OK', 'ok', 'Webhook 測試成功');
    } catch (err) {
      this.setStatus(`FAILED: ${err.message}`, 'err');
      log('ERR', 'err', `Webhook 測試失敗:${err.message}`);
    }
  },

  bindUi() {
    if (!whToggle) return;
    this.load();
    whToggle.checked = this.cfg.enabled;
    if (whUrl) whUrl.value = this.cfg.url;
    if (whToken) whToken.value = this.cfg.token;
    this.setStatus(this.cfg.enabled ? 'ARMED' : 'OFF', this.cfg.enabled ? 'ok' : '');

    whToggle.addEventListener('change', () => {
      this.cfg.enabled = whToggle.checked;
      this.save();
      this.setStatus(this.cfg.enabled ? 'ARMED' : 'OFF', this.cfg.enabled ? 'ok' : '');
      log('INFO', '', `Webhook 自動匯出 → ${this.cfg.enabled ? '啟用' : '停用'}`);
    });
    whUrl?.addEventListener('change', () => { this.cfg.url = whUrl.value.trim(); this.save(); });
    whToken?.addEventListener('change', () => { this.cfg.token = whToken.value.trim(); this.save(); });
    whTest?.addEventListener('click', () => this.test());
  },
};
webhook.bindUi();

// ══════════════════════════════════════════════════════════
// ── DLQ 錯誤報告匯出 ───────────────────────────────────────
// ══════════════════════════════════════════════════════════

btnErrReport?.addEventListener('click', () => {
  const report = {
    app: 'NEXPRESS',
    version: APP_VERSION,
    generatedAt: new Date().toISOString(),
    config: {
      format: selectedFormat,
      quality: parseInt(qualitySlider.value, 10) || null,
      threads: maxConcurrent,
      timezoneOverride: tzToggle.checked ? tzSelect.value : null,
      timeShift: tsToggle?.checked ? (tsInput?.value ?? null) : null,
    },
    totals: { attempted: totalTasks, succeeded: results.length, failed: deadLetters.length },
    failures: deadLetters,
  };
  const blob = new Blob([JSON.stringify(report, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const ts = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  Object.assign(document.createElement('a'), { href: url, download: `nexpress-error-report-${ts}.json` }).click();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
  log('OK', 'ok', `錯誤報告已匯出(${deadLetters.length} 筆失敗記錄)`);
});

// ══════════════════════════════════════════════════════════
// ── WebCodecs 硬體加速偵測(啟動時)─────────────────────────
// 偵測結果僅作能力回報與未來擴充依據。經完整評估(W3C WebCodecs AV1
// registration:API 不提供 av1C、encoder 一律丟棄 alpha、Chromium 僅
// 8-bit 4:2:0,Safari 無 AV1 encode),單張影像的硬體編碼封裝品質
// 低於現行 WASM still-image 編碼器 → 生產路徑「策略性優雅降級」至 WASM。
// ══════════════════════════════════════════════════════════

async function detectHardwareCaps() {
  const caps = { webcodecs: typeof VideoEncoder !== 'undefined', av1: false, hevc: false };
  if (caps.webcodecs) {
    const probe = async (codec) => {
      try {
        const r = await VideoEncoder.isConfigSupported({ codec, width: 1280, height: 720, bitrate: 2_000_000, framerate: 30 });
        return !!r?.supported;
      } catch { return false; }
    };
    [caps.av1, caps.hevc] = await Promise.all([
      probe('av01.0.04M.08'),
      probe('hvc1.1.6.L93.B0').then(ok => ok || probe('hev1.1.6.L93.B0')),
    ]);
  }
  window.__nx.hwCaps = caps;
  const label = [caps.av1 && 'AV1', caps.hevc && 'HEVC'].filter(Boolean).join('+') || 'NONE';
  if (instHw) {
    instHw.textContent = label;
    instHw.className = `inst-val ${label === 'NONE' ? 'dim' : ''}`;
  }
  if (instHwSub) instHwSub.textContent = 'HEIF: macOS ImageIO';
  log('SYS', 'dim', `WebCodecs capability │ ${caps.webcodecs ? `AVAILABLE (${label})` : 'UNAVAILABLE'} │ HEIF 使用 macOS ImageIO，其餘格式使用本機 WASM`);
  return caps;
}

// ══════════════════════════════════════════════════════════
// ── PWA:Service Worker 註冊 ──────────────────────────────
// ══════════════════════════════════════════════════════════

function queryServiceWorkerStatus(controller, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    if (!controller) return reject(new Error('page is not controlled'));
    const channel = new MessageChannel();
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      channel.port1.onmessage = null;
      channel.port1.close();
      callback(value);
    };
    const timer = setTimeout(
      () => finish(reject, new Error('offline readiness probe timed out')),
      timeoutMs,
    );
    channel.port1.onmessage = event => {
      finish(resolve, event.data);
    };
    try {
      controller.postMessage({ type: 'NX_GET_STATUS' }, [channel.port2]);
    } catch (error) {
      finish(reject, error);
    }
  });
}

async function waitForServiceWorkerController(timeoutMs = 5000) {
  if (navigator.serviceWorker.controller) return navigator.serviceWorker.controller;
  return new Promise(resolve => {
    const timer = setTimeout(() => {
      navigator.serviceWorker.removeEventListener('controllerchange', onChange);
      resolve(navigator.serviceWorker.controller || null);
    }, timeoutMs);
    const onChange = () => {
      clearTimeout(timer);
      navigator.serviceWorker.removeEventListener('controllerchange', onChange);
      resolve(navigator.serviceWorker.controller);
    };
    navigator.serviceWorker.addEventListener('controllerchange', onChange);
  });
}

async function waitForServiceWorkerReady(timeoutMs = 15000) {
  let timer;
  try {
    return await Promise.race([
      navigator.serviceWorker.ready,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Service Worker install did not become ready')), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function refreshPwaReadiness() {
  const controller = navigator.serviceWorker.controller;
  if (!controller) {
    if (cfgPwaStat) cfgPwaStat.textContent = 'INSTALLED';
    if (cfgPwaCopy) cfgPwaCopy.textContent = 'Service Worker 已安裝，但目前頁面尚未受控；重新整理後再驗證離線能力。';
    return null;
  }
  try {
    const registration = await navigator.serviceWorker.getRegistration();
    const replacementWorker = registration?.waiting
      || (registration?.active && registration.active !== controller ? registration.active : null);
    let replacementStatus = null;
    let replacementAssessment = null;
    if (replacementWorker) {
      try { replacementStatus = await queryServiceWorkerStatus(replacementWorker); } catch {}
      window.__nx.pwaWaitingStatus = replacementStatus;
      await buildIdentityReady;
      replacementAssessment = renderPendingBuild(replacementStatus);
    } else if (registration?.installing) {
      if (cfgPwaStat) cfgPwaStat.textContent = 'UPDATING';
      if (cfgPwaCopy) cfgPwaCopy.textContent = '新版本正在下載與驗證；完成後會提示重新整理。';
      return null;
    }

    let status;
    try {
      status = await queryServiceWorkerStatus(controller, replacementWorker ? 2500 : 8000);
    } catch (error) {
      if (replacementAssessment?.state === 'VERIFIED' && replacementStatus?.offlineReady) {
        const current = buildIdentityAssessment.current;
        setBuildIdentityAssessment({
          state: 'UNVERIFIED',
          reason: 'The legacy controlling Service Worker cannot report build identity; a verified replacement is ready.',
          current,
        });
        if (cfgPwaStat) cfgPwaStat.textContent = 'UPDATE READY';
        if (cfgPwaCopy) cfgPwaCopy.textContent = `新 Build ${replacementStatus.buildId} 已完整下載；重新整理後切換並完成 Runtime 驗證。`;
        log('INFO', 'inf', `Legacy Service Worker status unavailable; verified update ${replacementStatus.buildId} is ready`);
        return null;
      }
      throw error;
    }
    window.__nx.pwaStatus = status;
    await buildIdentityReady;
    if (!reconcileControllerBuild(status)) {
      if (cfgPwaStat) cfgPwaStat.textContent = 'DEGRADED';
      if (cfgPwaCopy) cfgPwaCopy.textContent = '目前控制器與頁面 Build ID 不一致；已停用離線就緒宣告。';
      return status;
    }
    if (replacementWorker) {
      if (replacementAssessment?.state === 'VERIFIED' && replacementStatus?.offlineReady) {
        if (cfgPwaStat) cfgPwaStat.textContent = 'UPDATE READY';
        if (cfgPwaCopy) cfgPwaCopy.textContent = `新 Build ${replacementStatus.buildId} 已完整下載；目前頁面仍執行 ${status.buildId}，重新整理後切換。`;
      } else {
        if (cfgPwaStat) cfgPwaStat.textContent = 'DEGRADED';
        if (cfgPwaCopy) cfgPwaCopy.textContent = '偵測到等待中的更新，但其 Build ID 或離線資產無法驗證。';
      }
      return status;
    }
    renderPendingBuild(null);
    if (status?.generation !== APP_VERSION) {
      if (cfgPwaStat) cfgPwaStat.textContent = 'UPDATE READY';
      if (cfgPwaCopy) cfgPwaCopy.textContent = `目前控制器為 ${status?.generation || 'unknown'}，應用程式為 ${APP_VERSION}；重新整理後切換完整世代。`;
      return status;
    }
    if (!status.offlineReady) {
      if (cfgPwaStat) cfgPwaStat.textContent = 'DEGRADED';
      if (cfgPwaCopy) cfgPwaCopy.textContent = `離線快取不完整：缺少 ${status.missing.join(', ')}`;
      log('WARN', 'wrn', `PWA offline cache incomplete: ${status.missing.join(', ')}`);
      return status;
    }
    if (cfgPwaStat) cfgPwaStat.textContent = 'OFFLINE READY';
    if (cfgPwaCopy) cfgPwaCopy.textContent = `離線世代 ${APP_VERSION} 已受控，核心引擎與哨兵資產驗證完成。`;
    log('OK', 'ok', `PWA offline generation ${APP_VERSION} verified and controlled`);
    return status;
  } catch (err) {
    if (cfgPwaStat) cfgPwaStat.textContent = 'DEGRADED';
    if (cfgPwaCopy) cfgPwaCopy.textContent = `無法驗證離線快取：${err.message}`;
    log('WARN', 'wrn', `PWA readiness verification failed: ${err.message}`);
    return null;
  }
}

async function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) {
    if (cfgPwaStat) cfgPwaStat.textContent = 'UNSUPPORTED';
    if (cfgPwaCopy) cfgPwaCopy.textContent = '此瀏覽器不支援 Service Worker,離線模式不可用。';
    log('WARN', 'wrn', 'Service Worker unsupported — 此瀏覽器無法使用 PWA 離線快取');
    return null;
  }
  try {
    if (cfgPwaStat) cfgPwaStat.textContent = 'REGISTERING';
    // updateViaCache:none 讓瀏覽器直接驗證遠端的 sw.js，不接受 HTTP cache 裡
    // 同 URL 的舊副本；Cloudflare 每次部署後，下一次開頁即可發現新世代。
    const reg = await navigator.serviceWorker.register('./sw.js', { updateViaCache: 'none' });
    const checkForUpdate = async (reason) => {
      try {
        await reg.update();
        if (reason) log('SYS', 'dim', `Service Worker update check │ ${reason} │ bypassed HTTP cache`);
        await refreshPwaReadiness();
      } catch (error) {
        log('WARN', 'wrn', `Service Worker update check failed: ${error.message}`);
      }
    };
    reg.addEventListener('updatefound', () => {
      const sw = reg.installing;
      sw?.addEventListener('statechange', () => {
        if (sw.state === 'installed' && navigator.serviceWorker.controller) {
          log('INFO', 'inf', '新版本已下載完成 — 重新整理頁面後生效');
          if (cfgPwaStat) cfgPwaStat.textContent = 'UPDATE READY';
          if (cfgPwaCopy) cfgPwaCopy.textContent = '新版本已完整下載；目前頁面保持既有世代，重新整理後切換。';
          // `statechange: installed` may fire just before registration.waiting
          // becomes observable. Re-probe on the next task without erasing the
          // immediate update signal.
          setTimeout(() => refreshPwaReadiness(), 0);
        }
      });
    });
    await checkForUpdate('startup');
    await waitForServiceWorkerReady();
    await waitForServiceWorkerController();
    const status = await refreshPwaReadiness();
    navigator.serviceWorker.addEventListener('controllerchange', () => refreshPwaReadiness());
    // 長時間開著的遠端分頁回到前景時也會主動確認部署，不需要等瀏覽器的
    // 預設 24 小時 Service Worker 檢查週期。
    const refreshWhenVisible = () => {
      if (document.visibilityState === 'visible') checkForUpdate('tab visible');
    };
    document.addEventListener('visibilitychange', refreshWhenVisible);
    window.addEventListener('focus', refreshWhenVisible);
    try {
      // Firefox headless occasionally leaves StorageManager.persist() pending
      // indefinitely. Persistence is only an optimisation, so never let this
      // optional capability probe block the complete application startup.
      const persistenceResult = await Promise.race([
        navigator.storage?.persist?.(),
        new Promise(resolve => setTimeout(() => resolve('TIMEOUT'), 2000)),
      ]);
      const persistenceLabel = persistenceResult === true ? 'GRANTED'
        : persistenceResult === 'TIMEOUT' ? 'TIMED OUT (BEST EFFORT)'
        : 'BEST EFFORT';
      log('SYS', 'dim', `Storage persistence │ ${persistenceLabel} │ 瀏覽器快取政策由本機環境管理`);
    } catch {
      log('SYS', 'dim', 'Storage persistence │ UNKNOWN │ 瀏覽器未提供查詢結果');
    }
    return status;
  } catch (err) {
    if (cfgPwaStat) cfgPwaStat.textContent = 'ERROR';
    if (cfgPwaCopy) cfgPwaCopy.textContent = `Service Worker 註冊失敗:${err.message}`;
    log('WARN', 'wrn', `Service Worker 註冊失敗:${err.message}`);
    return null;
  }
}

// ══════════════════════════════════════════════════════════
// ── 測試/除錯掛勾(Playwright 依賴,勿移除)─────────────────
// ══════════════════════════════════════════════════════════

window.__nx = {
  version: APP_VERSION,
  pageRuntimeIdentity: PAGE_RUNTIME_IDENTITY,
  buildIdentity: () => buildIdentityAssessment,
  buildIdentityReady,
  classifyBuildIdentity,
  validateBuildInfo,
  validateServiceWorkerStatus,
  queryServiceWorkerStatus,
  renderPendingBuild,
  PriorityQueue,
  computeTaskPriority,
  PRIORITY,
  estimator,
  deadLetters,
  webhook,
  parseTimeShiftInput,
  formatShiftLabel,
  getOutputFileName,
  getFileMetaKey,
  getFileMeta,
  setFileMeta,
  preview,
  workerPool,
  formatWorkerCapacity,
  slotHasFullCapability,
  refreshPwaReadiness,
  runtimeSnapshot: () => ({
    queued: taskQueue.length,
    trackedTasks: Object.keys(taskMap).length,
    busyWorkers: workerPool.filter(slot => slot.busy).length,
    readyWorkers,
    workerCount: workerPool.length,
    results: results.length,
    deadLetters: deadLetters.length,
    preReadFiles: preReadFiles.size,
    previewInflight: preview.inflightId ? 1 : 0,
  }),
  hwCaps: null,
};

syncTimezoneUi();
syncTimeShiftUi();
syncQualityUi();
applyTheme(loadThemePreference());
switchView('compress', { silent: true });
refreshInfoViews();

async function runStartupSequence() {
  const startedAt = performance.now();
  const logicalCores = navigator.hardwareConcurrency || 'unknown';
  const deviceMemory = navigator.deviceMemory ? `${navigator.deviceMemory} GiB hint` : 'not reported';

  log('SYS', 'dim', '══════════ SYS_COMPRESS STARTUP ══════════');
  log('INFO', '', `[BOOT 1/5] Runtime identity │ version ${APP_VERSION} │ generation ${PAGE_RUNTIME_IDENTITY.releaseGeneration || 'unverified'}`);
  log('SYS', 'dim', `Build identity │ ${PAGE_RUNTIME_IDENTITY.buildId || 'unverified'}`);
  log('SYS', 'dim', `Execution policy │ local Mac processing │ no image upload │ ${logicalCores} logical cores │ memory ${deviceMemory}`);

  log('INFO', '', '[BOOT 2/5] Browser capability probe');
  await detectHardwareCaps();

  log('INFO', '', `[BOOT 3/5] Compression engine │ spawning ${maxConcurrent} Workers │ max concurrency ${maxConcurrent}`);
  log('SYS', 'dim', 'Module plan │ JPEG · PNG · WebP · AVIF · JXL · HEIF · EXIF · ZIP');
  if (zipReady) {
    codecsLoaded = 1;
    log('OK', 'dim', '  [AUX] ZIP / JSZip — READY（批次封裝與同名檔案保護）');
  } else {
    log('WARN', 'wrn', '  [AUX] ZIP / JSZip — UNAVAILABLE（仍可逐檔下載）');
  }
  initializeWorkerPool();
  const engineResult = await Promise.race([
    initialEngineReady,
    new Promise(resolve => setTimeout(() => resolve({ state: 'TIMEOUT' }), 30000)),
  ]);

  log('INFO', '', '[BOOT 4/5] Offline runtime │ Service Worker、世代與核心資產驗證');
  const pwaStatus = await registerServiceWorker();

  const availableFormats = SUPPORTED_FORMATS.filter(format => formatWorkerCapacity(format) > 0).map(format => FMT_LABEL[format]);
  const elapsedMs = Math.round(performance.now() - startedAt);
  log('INFO', '', `[BOOT 5/5] Startup summary │ engine ${engineResult.state} │ formats ${availableFormats.length}/${SUPPORTED_FORMATS.length} │ offline ${pwaStatus?.offlineReady ? 'READY' : 'DEGRADED'}`);
  log(engineResult.state === 'ONLINE' ? 'OK' : 'WARN', engineResult.state === 'ONLINE' ? 'ok' : 'wrn', `SYS_COMPRESS ready in ${elapsedMs} ms │ ${availableFormats.join(' · ') || 'no encoder available'} │ queue awaiting input`);
  log('SYS', 'dim', '══════════ STARTUP COMPLETE ══════════');
}

runStartupSequence().catch(error => {
  log('ERR', 'err', `Startup sequence failed: ${error.message}`);
});

// ── Advanced zoom overlay logic ──
function closeZoomOverlay() {
  document.querySelector('.zoom-overlay')?._close?.();
}

function showZoomOverlay(srcUrl, compUrl, title, isCrop = false, onClose = null) {
  closeZoomOverlay();   // 換一張縮圖前先完整關閉上一個 overlay(含釋放 lazy blob URL)

  const overlay = document.createElement('div');
  overlay.className = 'zoom-overlay';
  // Sanitize URLs: only allow blob: and data: schemes, escape quotes for safety
  const sanitizeUrl = (u) => {
    if (typeof u !== 'string') return '';
    if (/^(blob:|data:)/i.test(u)) return u.replace(/"/g, '&quot;');
    return '';
  };
  const safeSrc = sanitizeUrl(srcUrl);
  const safeComp = sanitizeUrl(compUrl);
  overlay.innerHTML = `
    <div class="zoom-hdr">
      <div class="zoom-title">${esc(title)}</div>
      <div class="zoom-controls">
        <button class="zoom-btn active" id="zoomSyncBtn">🔗 同步對比</button>
        <button class="zoom-btn" id="zoomSingleBtn">🔲 單張放大</button>
        <div class="zoom-ab-toggle" id="zoomAbToggle" style="display: none; align-items: center; gap: 4px; margin-left: 8px; border-left: 1px solid rgba(255,255,255,0.15); padding-left: 8px;">
          <button class="zoom-btn" id="abSrcBtn">原始圖 ORIGINAL</button>
          <button class="zoom-btn" id="abCompBtn">壓縮圖 COMPRESSED</button>
        </div>
      </div>
      <button class="zoom-close" id="zoomCloseBtn">CLOSE ✕</button>
    </div>
    <div class="zoom-content">
      <div class="zoom-pane ${isCrop ? 'is-crop' : ''}">
        <div class="zoom-pane-title">SOURCE / ORIGINAL</div>
        <div class="zoom-img-wrap">
          <img id="zoomSrcImg" src="${safeSrc}" alt="Original">
        </div>
      </div>
      <div class="zoom-pane ${isCrop ? 'is-crop' : ''}">
        <div class="zoom-pane-title">COMPRESSED</div>
        <div class="zoom-img-wrap">
          <img id="zoomCompImg" src="${safeComp}" alt="Compressed">
        </div>
      </div>
    </div>
  `;

  document.body.appendChild(overlay);

  const srcImg = overlay.querySelector('#zoomSrcImg');
  const compImg = overlay.querySelector('#zoomCompImg');
  const srcWrap = srcImg?.closest('.zoom-img-wrap');
  const compWrap = compImg?.closest('.zoom-img-wrap');

  const onEscKey = (e) => { if (e.key === 'Escape') close(); };
  const close = () => {
    document.removeEventListener('keydown', onEscKey);
    if (document.body.contains(overlay)) overlay.remove();
    if (onClose) onClose();
  };
  document.addEventListener('keydown', onEscKey);
  overlay._close = close;   // 唯一的拆除入口,供 closeZoomOverlay() 呼叫

  // Only close overlay when clicking background, not when clicking image wrapper or image itself
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay || e.target.classList.contains('zoom-content') || e.target.classList.contains('zoom-pane')) {
      close();
    }
  });

  const closeBtn = overlay.querySelector('#zoomCloseBtn');
  if (closeBtn) closeBtn.addEventListener('click', close);

  let zoomMode = 'sync'; // 'sync' | 'single'
  const syncBtn = overlay.querySelector('#zoomSyncBtn');
  const singleBtn = overlay.querySelector('#zoomSingleBtn');
  const abToggle = overlay.querySelector('#zoomAbToggle');
  const abSrcBtn = overlay.querySelector('#abSrcBtn');
  const abCompBtn = overlay.querySelector('#abCompBtn');

  const updateAbToggleButtons = () => {
    const srcZoomed = srcImg?.classList.contains('zoomed');
    const compZoomed = compImg?.classList.contains('zoomed');
    if (abSrcBtn && abCompBtn) {
      abSrcBtn.classList.toggle('active', srcZoomed);
      abCompBtn.classList.toggle('active', compZoomed);
    }
  };

  const applyToPane = (targetImg, zoomed) => {
    const w = targetImg.closest('.zoom-img-wrap');
    if (!w) return;
    w.classList.toggle('zoomed-wrap', zoomed);
    targetImg.classList.toggle('zoomed', zoomed);

    const pane = targetImg.closest('.zoom-pane');
    if (pane) pane.classList.toggle('zoomed-pane', zoomed);
  };

  const zoomOutAll = () => {
    if (srcImg) applyToPane(srcImg, false);
    if (compImg) applyToPane(compImg, false);
    overlay.classList.remove('has-zoomed-pane');
    updateAbToggleButtons();
  };

  const handleAbBtnClick = (targetImg, otherImg) => {
    const isCurrentlyZoomed = targetImg.classList.contains('zoomed');
    if (isCurrentlyZoomed) {
      zoomOutAll();
    } else {
      const targetWrap = targetImg.closest('.zoom-img-wrap');
      const otherWrap = otherImg.closest('.zoom-img-wrap');

      let scrollLeftVal = 0;
      let scrollTopVal = 0;
      const isOtherZoomed = otherImg.classList.contains('zoomed');
      if (isOtherZoomed && otherWrap) {
        scrollLeftVal = otherWrap.scrollLeft;
        scrollTopVal = otherWrap.scrollTop;
      }

      applyToPane(targetImg, true);
      applyToPane(otherImg, false);
      overlay.classList.add('has-zoomed-pane');

      updateAbToggleButtons();

      if (targetWrap) {
        setTimeout(() => {
          if (isOtherZoomed) {
            targetWrap.scrollLeft = scrollLeftVal;
            targetWrap.scrollTop = scrollTopVal;
          } else {
            targetWrap.scrollLeft = (targetWrap.scrollWidth - targetWrap.clientWidth) / 2;
            targetWrap.scrollTop = (targetWrap.scrollHeight - targetWrap.clientHeight) / 2;
          }
        }, 10);
      }
    }
  };

  if (abSrcBtn && srcImg && compImg) {
    abSrcBtn.addEventListener('click', () => handleAbBtnClick(srcImg, compImg));
  }
  if (abCompBtn && srcImg && compImg) {
    abCompBtn.addEventListener('click', () => handleAbBtnClick(compImg, srcImg));
  }

  const setZoomMode = (mode) => {
    zoomMode = mode;
    if (syncBtn && singleBtn) {
      syncBtn.classList.toggle('active', mode === 'sync');
      singleBtn.classList.toggle('active', mode === 'single');
    }
    if (abToggle) {
      abToggle.style.display = mode === 'single' ? 'flex' : 'none';
    }

    // Reset zoom state on mode switch to avoid layout glitches
    zoomOutAll();
  };

  if (syncBtn) syncBtn.addEventListener('click', () => setZoomMode('sync'));
  if (singleBtn) singleBtn.addEventListener('click', () => setZoomMode('single'));

  const toggleZoom = (img) => {
    const wrap = img.closest('.zoom-img-wrap');
    if (!wrap) return;
    const isZoomed = !wrap.classList.contains('zoomed-wrap');

    if (zoomMode === 'sync') {
      if (srcImg) applyToPane(srcImg, isZoomed);
      if (compImg) applyToPane(compImg, isZoomed);
      overlay.classList.toggle('has-zoomed-pane', false);

      if (isZoomed && srcWrap && compWrap) {
        setTimeout(() => {
          const centerX = (srcWrap.scrollWidth - srcWrap.clientWidth) / 2;
          const centerY = (srcWrap.scrollHeight - srcWrap.clientHeight) / 2;
          srcWrap.scrollLeft = compWrap.scrollLeft = centerX;
          srcWrap.scrollTop = compWrap.scrollTop = centerY;
        }, 10);
      }
    } else {
      const otherImg = img === srcImg ? compImg : srcImg;
      if (otherImg) {
        handleAbBtnClick(img, otherImg);
      }
    }
  };

  let dragMoved = false;

  const setupDragToPan = (wrap) => {
    if (!wrap) return;
    let isDown = false;
    let startX, startY;
    let scrollLeftVal, scrollTopVal;

    wrap.addEventListener('mousedown', (e) => {
      if (!wrap.classList.contains('zoomed-wrap')) return;
      isDown = true;
      dragMoved = false;
      wrap.style.cursor = 'grabbing';
      startX = e.pageX - wrap.offsetLeft;
      startY = e.pageY - wrap.offsetTop;
      scrollLeftVal = wrap.scrollLeft;
      scrollTopVal = wrap.scrollTop;
    });

    wrap.addEventListener('mouseleave', () => {
      if (!isDown) return;
      isDown = false;
      wrap.style.cursor = 'grab';
    });

    wrap.addEventListener('mouseup', () => {
      if (!isDown) return;
      isDown = false;
      wrap.style.cursor = 'grab';
    });

    wrap.addEventListener('mousemove', (e) => {
      if (!isDown) return;
      const x = e.pageX - wrap.offsetLeft;
      const y = e.pageY - wrap.offsetTop;
      const walkX = x - startX;
      const walkY = y - startY;

      if (Math.abs(walkX) > 5 || Math.abs(walkY) > 5) {
        dragMoved = true;
      }

      if (dragMoved) {
        e.preventDefault();
        wrap.scrollLeft = scrollLeftVal - walkX;
        wrap.scrollTop = scrollTopVal - walkY;
      }
    });
  };

  setupDragToPan(srcWrap);
  setupDragToPan(compWrap);

  // 同步捲動:programmatic 設定 scrollLeft/Top 觸發的 scroll 事件是「非同步」派發的,
  // 舊的同步布林鎖(isSyncingScroll)在 echo 事件觸發前就已重設 → 過濾不到 echo。
  // 快速捲動時,對側 programmatic 更新的舊 echo 會把正在前進的一側拉回 → 抖動。
  // 改用「方向性忽略旗標 + requestAnimationFrame」:驅動對方前,先把對方的忽略旗標
  // 設 true,並排程在下一個動畫幀重設。programmatic echo 必在當前幀內派發 → 被 100%
  // 過濾;下一幀使用者對該側的真實捲動不受影響(rAF 已把旗標放開)。
  let ignoreSrcScroll = false;
  let ignoreCompScroll = false;
  const syncScroll = (fromWrap, toWrap, source) => {
    if (zoomMode !== 'sync' || !fromWrap || !toWrap) return;
    if (source === 'src' && ignoreSrcScroll) return;
    if (source === 'comp' && ignoreCompScroll) return;
    // 已同步就不重設,省下一次 programmatic 寫入(也少一次 echo)
    if (Math.abs(toWrap.scrollLeft - fromWrap.scrollLeft) < 1 &&
        Math.abs(toWrap.scrollTop - fromWrap.scrollTop) < 1) return;
    if (source === 'src') { ignoreCompScroll = true; requestAnimationFrame(() => { ignoreCompScroll = false; }); }
    else { ignoreSrcScroll = true; requestAnimationFrame(() => { ignoreSrcScroll = false; }); }
    toWrap.scrollLeft = fromWrap.scrollLeft;
    toWrap.scrollTop = fromWrap.scrollTop;
  };

  if (srcWrap && compWrap) {
    srcWrap.addEventListener('scroll', () => syncScroll(srcWrap, compWrap, 'src'));
    compWrap.addEventListener('scroll', () => syncScroll(compWrap, srcWrap, 'comp'));
  }

  const handleImageClick = (e, img) => {
    e.stopPropagation();
    if (dragMoved) {
      dragMoved = false;
      return;
    }
    toggleZoom(img);
  };

  if (srcImg) {
    srcImg.addEventListener('click', (e) => handleImageClick(e, srcImg));
  }
  if (compImg) {
    compImg.addEventListener('click', (e) => handleImageClick(e, compImg));
  }

  const handleImgError = (img, label) => {
    const wrap = img.parentNode;
    if (wrap) {
      wrap.innerHTML = `
        <div style="color:var(--ts);font-family:var(--mono);font-size: 13px;text-align:center;padding:20px;">
          無法在此瀏覽器直接預覽<br>
          <span style="font-size: 11px;opacity:0.7;">(格式: ${label})</span>
        </div>
      `;
    }
  };

  if (srcImg) srcImg.onerror = () => handleImgError(srcImg, 'Original');
  if (compImg) compImg.onerror = () => handleImgError(compImg, 'Compressed');
}

// ── Results grid click event for zoom-in ──
resultsGrid.addEventListener('click', (e) => {
  const thumb = e.target.closest('.rc-thumb');
  if (!thumb) return;
  e.preventDefault();
  const card = e.target.closest('.result-card');
  if (card && card._result) {
    const res = card._result;
    const compUrl = res.previewUrl || res.url;
    // HEIF/JXL:右側為縮小後的 JPEG 預覽，標題註明避免誤導畫質判斷。
    const title = isAsyncPreviewFormat(res.format)
      ? `${res.fileName} — 右側為 JPEG 轉檔預覽,非實際輸出畫質`
      : res.fileName;
    // 只在使用者實際點開時才建立原圖 blob URL,關閉 overlay 就釋放,
    // 避免整批檔案的原圖 URL 從頭到尾都佔著記憶體。
    const origUrl = URL.createObjectURL(res.file);
    showZoomOverlay(origUrl, compUrl, title, false, () => URL.revokeObjectURL(origUrl));
  }
});

// ── Live Preview click event for zoom-in ──
const openLivePreviewZoom = () => {
  const pvOrig = $('pvOrig');
  const pvComp = $('pvComp');
  if (!pvOrig || !pvComp) return;
  try {
    const srcData = pvOrig.toDataURL('image/png');
    const compData = pvComp.toDataURL('image/png');
    const fileName = preview.sourceFile ? preview.sourceFile.name : 'Crop Preview';
    showZoomOverlay(srcData, compData, `300x300 Crop - ${fileName}`, true);
  } catch (err) {
    console.warn('Failed to zoom live preview:', err);
  }
};

$('pvOrig')?.addEventListener('click', openLivePreviewZoom);
$('pvComp')?.addEventListener('click', openLivePreviewZoom);

// ── Collapsible Timezone click event ──
const toggleTzCollapse = () => {
  const container = $('tzCollapsible');
  const btn = $('tzCollapseBtn');
  if (!container || !btn) return;
  const isCollapsed = container.classList.toggle('collapsed');
  btn.textContent = isCollapsed ? '▼' : '▲';
  log('INFO', '', `EXIF Timezone 面板 ${isCollapsed ? '已收合' : '已展開'}`);
};

$('tzSecHd')?.addEventListener('click', toggleTzCollapse);
$('tzCollapseBtn')?.addEventListener('click', (e) => {
  e.stopPropagation();
  toggleTzCollapse();
});
