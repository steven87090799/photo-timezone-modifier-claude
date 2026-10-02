# ON1 Photo RAW 真實驗收

這個驗收必須在實際安裝 ON1 Photo RAW 的 **macOS 27+ Apple Silicon Mac** 上執行。CI 不會模擬 ON1 UI，也不把 ON1 的專有程式當測試相依項目。

## A / B / C / C0

1. **A**：相機原始檔的獨立測試副本，保留原本缺少時區的狀態。
2. **B**：用本 App 對 A 的另一份副本補上三個 EXIF 時區欄位。確認 DateTimeOriginal 不變。
3. **C**：把 B 匯入 ON1 Photo RAW，不做時間修正，再由 ON1 匯出。
4. **C0**（建議）：把 A 直接匯入 ON1，再用相同設定匯出，作為未補時區的基線。

ON1 匯出可能重新壓縮影像，所以 **B 與 C 不做整檔 HASH 相等要求**。

## 執行

```bash
./scripts/on1-acceptance.sh A.ARW B.ARW C.jpg C0.jpg
```

腳本會檢查：
- A → B 的 `DateTimeOriginal` 必須完全相同。
- B 必須能讀到 `OffsetTimeOriginal`、`OffsetTimeDigitized`、`OffsetTime`。
- B → C 經過 ON1 匯出後，`DateTimeOriginal` 不得被平移。
- 若提供 C0，會另外顯示未補時區基線是否被 ON1 平移。

## 建議 fixture

至少保留一張你實際使用相機的 ARW 測試副本，並測：
- 無三欄時區。
- 三欄已有相同時區。
- 三欄部分缺漏。
- 內嵌 XMP 或 XMP sidecar 存在時。

每次升級 ON1 或 ExifTool 後重新跑一次。
