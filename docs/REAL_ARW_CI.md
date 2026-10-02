# 真實 Sony ARW 回歸測試

Production 不計算照片 HASH；**測試 fixture 可以計算**，因為它是可丟棄的測試副本。

## 測試內容

`PhotoEngineTests.testRealSonyARWTimezoneGPSAndRestoreRegression` 會對真實 Sony ARW 的獨立副本驗證：

- ExifTool 實際辨識為 `ARW` 且 Make 為 Sony。
- 三個 EXIF OffsetTime 寫入後，DateTimeOriginal／CreateDate／ModifyDate／次秒不變。
- 測試用 `ImageDataHash` 在寫入前後相同。
- `_original` 備份可由 provenance 驗證，restore 後整檔 SHA-256 回到 fixture 原始值。
- 無既有 GPS 的另一份 ARW 可新增 GPS，而且既有日期、時區與 image payload 不變。

## 本機執行

```bash
PHOTO_TIMEZONE_REAL_ARW="/path/to/real-sony.ARW" ./scripts/test.sh --filter testRealSonyARWTimezoneGPSAndRestoreRegression
```

## GitHub Actions

`workflow_dispatch` 提供：

- `real_arw_url`：直接下載真實 Sony ARW 的 URL。
- `real_arw_sha256`：該檔案的 SHA-256。

CI 會先驗證 SHA-256，再把路徑放進 `PHOTO_TIMEZONE_REAL_ARW`，然後由完整 native test suite 執行真實 RAW 測試。

Fixture 必須是可以合法用於自動測試的 RAW。建議使用 raw.pixls.us 的 **CC0** Sony 樣本或你自己的專用測試照片；不要把授權不明的攝影作品直接提交進 repository。
