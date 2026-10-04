# 副本輸出失敗：延伸屬性與 XMP 分鐘精度

2026-10-04 的本機案例使用最新正式版 3.5.0 build 98。55 張 JPEG 的副本輸出全部失敗：54 張回報 `Extended attributes differ; original not changed.`，另 1 張因 XMP 日期只有分鐘精度而被拒絕。來源照片未提交任何修改。

## 延伸屬性原因與修正

來源與輸出在不同磁碟卷，`clonefile` 回傳 `EXDEV`，改用 `FileManager.copyItem`。以其中一張實際照片重現後，發現原生複製更新了 `com.apple.quarantine`，並新增 `com.apple.provenance`。這些差異在 ExifTool 寫入前就已存在；其他延伸屬性相同，ExifTool 寫入成功。

修正保留候選檔由 macOS 建立的隔離與 provenance 記錄，不清除或用來源值覆蓋它們。這兩個屬性不再要求與來源逐位元相同。來源已有非空隔離標記而候選檔遺失標記時，仍拒絕處理。其他屬性、檔案時間與權限繼續嚴格驗證；延伸屬性錯誤以繁體中文列出不符的名稱。

## XMP 分鐘精度原因與修正

原檢查只接受含秒數的日期，但 [Adobe XMP Date 規格](https://developer.adobe.com/xmp/docs/xmp-namespaces/xmp-data-types/) 也允許 `YYYY-MM-DDThh:mm`。修正允許有完整日期與時、分的值，加上指定偏移時保留原本精度；不補造秒數、不平移鐘點。內嵌 XMP 與既有 sidecar 都適用。

## 驗證

- 新增的兩個失敗案例在修正前重現相同錯誤，修正後通過。
- macOS 安全標記在候選檔保留原值；一般屬性被改動、隔離標記遺失時，仍拒絕候選檔。
- 同一批實際 55 張 JPEG 使用 App 的 `PhotoEngine` 副本處理流程，55 張全部成功。逐張核對來源完整內容與檔案身分、拍攝時間、JPEG 影像資料、ICC 相同。測試只在暫存目錄產生副本，結束後移除副本。
- 完整回歸：103 項通過，4 項 opt-in 測試略過。實際 JPEG 目錄測試已另外啟用並通過；真實 ARW 與兩項 1,000 張壓力測試本次未執行。
- 原生桌面控制工具在取得既有失敗畫面後持續逾時，因此上述實際照片驗收直接呼叫 App 使用的同一套處理引擎，未宣稱已用修正版 UI 完成點擊操作。

在 macOS 27／CLT 環境使用 `scripts/test.sh` 載入 Testing 巨集；建置暫存放在 Documents 外，避免 FileProvider 對測試 bundle 加上 FinderInfo 而影響簽章。

```bash
./scripts/test.sh --scratch-path /private/tmp/PhotoTimezone-tests
PHOTO_TIMEZONE_REAL_JPEG_DIRECTORY='/你的測試相片資料夾' \
  ./scripts/test.sh --scratch-path /private/tmp/PhotoTimezone-tests \
  --filter testRealJPEGDirectoryCopyPreservesOriginalsAndImageData
```

這份驗證針對本機修正程式碼；當時已安裝的 build 98 與 GitHub 最新 ZIP 尚未包含修正。
