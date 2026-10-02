# ON1 Photo RAW acceptance test

這個驗證用來確認最初的實際問題：照片缺少 EXIF 時區時，ON1 匯出後是否會把拍攝鐘點解讀成另一個時間；以及補齊三個標準 EXIF 時區後，ON1 是否保持原本的拍攝鐘點。

## 測試環境

目前產品基線為 **Apple Silicon（M 系列）+ macOS 27 或更新版本**。ON1 是商業桌面應用程式，因此 GitHub Actions 不會假裝執行 ON1；此測試要在實際安裝 ON1 Photo RAW 的 Mac 上完成一次。驗證腳本本身只讀四個測試檔案。

## 四個檔案

使用同一張可丟棄測試照片建立：

- **A**：完全未經 PhotoTimezone 修改的來源。
- **B**：以 PhotoTimezone 補齊／設定三個 EXIF 時區後的結果。
- **C**：把 B 匯入 ON1，再用日常會使用的設定匯出。
- **C0**：把 A 匯入 ON1，用與 C 完全相同的設定匯出，作為未補時區基準。

不要拿正式唯一原檔做 acceptance。A/B 應是獨立測試副本。

## 操作步驟

1. 複製一張測試照片為 A。
2. 在 PhotoTimezone 掃描 A，確認拍攝鐘點，然後以副本模式建立 B。
3. 重新讀取 B，確認三個欄位均存在：
   - ExifIFD:OffsetTimeOriginal
   - ExifIFD:OffsetTimeDigitized
   - ExifIFD:OffsetTime
4. 將 B 匯入 ON1 Photo RAW，依正常工作流程匯出成 C。
5. 將 A 以相同 ON1 設定匯出成 C0。
6. 執行：

    bash ./scripts/verify-on1-acceptance.sh \
      "/path/A.ARW" \
      "/path/B.ARW" \
      "/path/C.jpg" \
      "/path/C0.jpg"

## 自動判斷

腳本會 fail closed：

- A → B 的 DateTimeOriginal、CreateDate、ModifyDate 任一改變：**FAIL**。
- B 的三個 EXIF 時區缺少或超出 UTC−12:00～UTC+14:00：**FAIL**。
- B → C 的 DateTimeOriginal 改變：**FAIL**。
- C0 只作基準；若 A → C0 有時差，腳本會列為 INFO，方便證明「未補時區」與「已補時區」兩條路徑的差異。

ON1 匯出 JPEG/TIFF 可能重編碼影像，因此 B 與 C **不要求整檔 HASH 相同**。本測試的判斷核心是拍攝鐘點與 EXIF 時區語意，不把重新壓縮誤判成失敗。

## 建議保存

每次升級 ON1 或 ExifTool 後，保留 A/B/C/C0 與腳本輸出。若之後 ON1 行為改變，可直接比較版本，而不必憑 UI 顯示猜測。
