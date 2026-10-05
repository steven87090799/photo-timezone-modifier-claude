# 相片時區修改器 3.6.0（Jpegli 分支）

原生 macOS SwiftUI 工具。修圖前在「相片處理」批次處理 JPEG、TIFF、Sony ARW 的時區與 GPS；修圖匯出後在獨立的「影像壓縮」頁處理輸出圖片。壓縮頁不修改時區或 GPS。

## 這版的寫入規則

介面與核心預設一致：處理三個標準 EXIF 欄位，預設僅補缺漏，預設輸出獨立副本。「覆寫所選時區」才會替換既有偏移。照片內嵌 XMP 與已存在的同名 `.xmp` 中，對應日期缺少時區時會補上相同偏移，保留原本的日期與鐘點。EXIF 與 XMP 已有不同偏移時，預設逐張報告衝突；明確覆寫才會同步指定偏移。沒有既有 sidecar 時不建立新的 sidecar。

| 時區標籤 | 對應日期（不會修改） |
|---|---|
| `ExifIFD:OffsetTimeOriginal` | `ExifIFD:DateTimeOriginal` |
| `ExifIFD:OffsetTimeDigitized` | `ExifIFD:CreateDate` |
| `ExifIFD:OffsetTime` | `IFD0:ModifyDate` |

EXIF 日期與次秒必須在寫入前後相同；XMP 日期只能變更時區尾碼，不能平移原有鐘點。XMP 只有分鐘精度時保留原本精度，不補造秒數。缺少的建立或修改日期不會被捏造；非法拍攝日期會被拒絕。固定 UTC 偏移不是城市時區，不會自動推斷夏令時間。

## 批次 GPS

「加入 GPS 位置」使用一組手動輸入的經緯度，處理本次匯入掃描的**全部**支援照片；啟用包含子資料夾時涵蓋其中照片。搜尋、篩選和單張選取只影響時區處理範圍，不會縮小 GPS 批次。預設只補完全沒有 EXIF、內嵌 XMP、同名 `.xmp` GPS 的照片。已有完整或部分 GPS 會保留原值；無法可靠讀取 sidecar 的照片逐張失敗並寫明原因。

另外勾選「GPS 覆蓋」才會改寫既有座標。照片和既有 XMP sidecar 的位置一起準備、讀回驗證；遇到無法安全同步的 XMP 位置結構會拒絕該照片，而不宣稱只改一處為成功。照片與 sidecar 在原檔模式各有耐久備份；多檔發佈失敗會嘗試回復並留下交易紀錄供人工核對。兩張照片共用同一個 XMP sidecar 時，為避免歸屬不明，兩張都會拒絕自動寫入。

## 效能與安全界線

依使用者選擇，**正式處理流程不再計算整檔、影像、縮圖或 MakerNotes HASH**。仍保留高精度可讀中繼資料比對、檔案身分與時間檢查、候選副本、原檔備份、安全提交與交易紀錄。

一般延伸屬性（包括 Finder 標籤、資源分支和自訂屬性）仍逐位元比對。macOS 原生複製可能更新 `com.apple.quarantine`，並為新檔案產生 `com.apple.provenance`，跨磁碟卷輸出副本時尤其常見；這兩個系統安全屬性保留目的檔由 macOS 產生的值，不要求與來源逐位元一致，也不清除或覆蓋它們。來源已有非空隔離標記而候選檔遺失標記時，仍拒絕寫入；其他延伸屬性不符則以繁體中文列出屬性名稱。

**中繼資料相同不能證明影像或未公開私有位元組相同。** Sony 相容模式僅放行明列的位置指標重排，不宣稱 RAW 私有區塊完整性認證。重要照片仍需另一顆磁碟的獨立備份。

ExifTool 在單次工作中重用，定期回收；進度事件有界線，清單排序移到背景並快取；縮圖最多 8 張與 8 MiB。不為側欄強制解碼整張 ARW。單次中繼資料輸出上限 16 MiB，超限不接受部分結果。

## ON1 / Lightroom / Immich / Google 相簿

現有內嵌 XMP 與 `.xmp` 會同步補齊或明確覆寫時區及 GPS。`.on1`、`.acr` 等專有伴隨檔仍原樣複製，不改其私有內容；副本同名衝突會停止該張照片的發布。XMP 日期的原本鐘點不平移，其他修圖設定與非位置欄位以寫入前後的可讀中繼資料比對保護。

雲端圖庫與編目資料庫不一定自動更新。本版不宣稱已在 CI 內啟動 ON1／Lightroom／Immich／Google Photos。ON1 提供 A/B/C/C0 實機驗證流程與自動判讀腳本，見 [ON1 acceptance](docs/ON1_ACCEPTANCE.md)。

## 相片預覽與掃描報告

掃描報告固定在相片處理頁底部，總計、完成、略過、失敗與取消以單列呈現。按「詳情」查看完整訊息與失敗原因，或由底列匯出記錄；相片清單每張維持單列。搜尋、狀態、相機與排序整合在同一行，搜尋框限制寬度；操作說明可由張數旁的問號查看。清單用滑鼠滾輪或觸控板連續捲動全部篩選結果，沒有每頁 200 張的切換限制。Shift／Command 可複選，「選取篩選結果」涵蓋全部符合項目。

相片清單使用主要剩餘空間，不以張數縮小或限制最高高度。選取相片後，縮圖、相機摘要、拍攝時間與三種時區、GPS 狀態及經緯度／高度橫向排列。一般資訊區高 166 點；按「顯示更多 EXIF 資訊」展開其他日期、GPS 日期／時間／方向、次秒、序號與詳細規格，資訊區最高 280 點並可獨立捲動。切換照片時重新收合，讓清單取得更多高度。長欄位與標籤可滑鼠停留查看全文。日期缺漏、EXIF／XMP 時區衝突及相關警告使用繁體中文。

## 影像壓縮與中繼資料

壓縮頁採用與相片處理一致的原生 SwiftUI 介面：左側設定、中央批次清單與進度、右側預覽與每張結果。保留 JPEG、PNG、WebP、AVIF、HEIF、JPEG XL 六種格式、品質與並行設定、拖放與資料夾匯入、預覽估算、放大比較、單張／整批／ZIP 儲存、CSV 報告及選用 Webhook。切換分頁會保留工作狀態；離開壓縮頁且無工作時會釋放引擎。HEIF／HEIC 由 macOS ImageIO 原生編解碼。

輸出時透過內建 ExifTool 複製並核對一般 EXIF、XMP、IPTC 與 ICC，包括原有時區及 GPS；本頁沒有修改時區或 GPS 的控制。JPEG、PNG、WebP、HEIF 優先保留來源 RGB ICC；AVIF 使用 sRGB 像素並逐張明示色彩轉換；JPEG XL 內嵌來源 ICC，並驗證轉換後色彩特性。容器不支援或無法核對的欄位會列在結果中，不能視為完整保留；ICC 不符而可能造成錯色時拒絕該張輸出。高位元及動畫輸入仍有限制，詳見 [影像壓縮整合說明](docs/COMPRESSION_INTEGRATION.md)。

### 3.5.1 修復

測試與資源實測見 [3.5.1 驗證紀錄](docs/REPAIR_VALIDATION_3.5.1.md)。

六種輸出與 PNG／HEIF／TIFF 等輸入使用獨立的中繼資料讀取政策，不再受到時區寫入格式限制。XMP 以完整封包複製，保留 ON1 等未知私有欄位；EXIF 合法位置重排與容器的 Copy 編號改變不再誤報遺失，仍比對每個重複值。PNG 努力度已接上 OxiPNG。3.5.1 使用 MozJPEG；本分支的替換見下方。

相片處理頁與 JPEG／JPEG XL／HEIF 原生壓縮不啟動 WebKit；8 位元 PNG／WebP／AVIF 工作才按需載入 WebKit。工作結束閒置 5 秒釋放整個引擎及本機服務；離開分頁時也會在工作結束後釋放。縮圖按需載入並設快取上限，並行數依尺寸、格式及記憶體調低。估算不等於整個程式的硬記憶體上限。

### 3.6.0 原生 Jpegli

依使用者決定，在 `codex/native-jpegli` 分支將 JPEG 編碼器替換為原生 Jpegli，移除 MozJPEG 的 JavaScript／WASM。輸出仍是普通 `.jpg`，8 位元 YCbCr、漸進式 Huffman JPEG，不使用 XYB 或 JPEG XL。預覽和正式輸出都使用同一編碼器。新安裝預設品質為 86；舊版預設 82 會升至 86，使用者自訂品質值保留。JPEG 品質 100 仍是有損；透明輸入轉白底。

Jpegli 編碼器可在 macOS 和 Windows 建置，普通 JPEG 可由兩平台的一般解碼器開啟；**這個 SwiftUI App 目前仍只支援 macOS**。因此直接替換，不增加依平台選擇的兩套 JPEG 模式。來源 RGB ICC、EXIF、XMP、IPTC 與原時區／GPS 沿用既有保留及驗證。固定來源版本、相容性證據與本機驗證見 [Jpegli 整合紀錄](docs/NATIVE_JPEGLI.md)；原方案比較保留在 [JPEG 方案比較](docs/JPEG_OPTIONS.md)。此分支尚未合併至 main。

「開始壓縮」產生暫存結果，**不會因為選了輸出資料夾就自動儲存**；請按「儲存單張」或「輸出 → 儲存全部」。介面會提示儲存狀態。JPEG XL 品質 100 失敗時明確報錯，不會自動降為品質 99。關閉最後一個視窗會退出程式；仍在寫入時需先停止或等待完成。

### 3.6.1 修復與實拍校準

[完整修復與測試報告](docs/COMPRESSION_FIX_20261005.md)。JPEG 建議品質 86，HEIF 建議 70，各格式獨立記憶品質；既有自訂值保留，可按「建議品質」恢復建議值。43 張实拍 JPEG 86 總容量減少 7.54%，HEIF 70 減少 15.58%，後者畫質評分較低；沒有適用所有照片的完美品質值。

正式結果以寫入中繼資料後的實際 bytes 計算減少比例；批次按成功來源與對應輸出總大小計算。放大比較使用同位置原生解析度裁切。PNG 16 位元與 JXL 100 支援整數 RGB／RGBA 樣本保留；無法保證無損的來源明確停止，其他格式降精度時提示。關閉最後視窗會退出，並停止本 App 擁有的子程序與本機服務。

### 3.6.2 JPG／HEIC 保留與清單資訊

同格式輸出保留完整檔名，互轉只換副檔名；同名衝突會提示而不自動改名。JPG／HEIC 保留拍攝 EXIF、原方向、既有時區／GPS，並核對 MakerNotes／EXIF 縮圖；關鍵資訊無法保留時拒絕輸出。清單加入相機、尺寸、曝光、拍攝時間、時區、GPS 與容量差額。172 份實際輸出及八種方向驗證詳見 [JPG／HEIC 驗證紀錄](docs/JPG_HEIC_VALIDATION_20261005.md)，其中列出 EXIF 編碼結構與介面驗收的界線。

### 3.6.3 原生介面調整

頁面切換固定在原生工具列；介面跟隨 macOS 的淺色／深色外觀，設定以分組表單呈現，較少使用的選項收合。品質滑桿移除密集刻度，但仍採整數品質。壓縮清單改為橫向三區：檔案／相機、拍攝／時區／GPS、狀態／容量；「已完成」正下方以綠色顯示減少比例、橘色顯示增加比例，並列出壓縮前後大小。並行數可選 1～8，實際仍依尺寸、格式及記憶體自動調低；既有設定保留。操作與建置界線見 [3.6.3 介面說明](docs/MACOS_UI_3.6.3.md)。

## 復原與異常提交

「從原始備份還原」是**整檔還原**，不是僅撤銷時區；還原前會另存當前版本。不會自動刪除你的備份。既有 `_original` 必須能由 PhotoTimezone 的 durable transaction provenance 證明來源，否則自動還原／再次原檔寫入會被拒絕。

發布后的同步錯誤會標記「已發布但未確認」，阻止盲目重試。由「資訊」選單開啟交易復原檢視；人工確認只封存紀錄，不會偷刪檔或自動重試。若 crash 發生在發布前，只有身分、路徑與 UUID 都能對上的 disposable candidate 才會自動清理。診斷頁另提供 Logs／非 provenance 歷史記錄與孤立候選的顯式清理；照片備份只統計、不自動刪除。

## 下載 App

[下載最新版 macOS App](https://github.com/steven87090799/photo-timezone-modifier-claude/releases/latest/download/PhotoTimezone-macOS.zip) · [所有建置版本](https://github.com/steven87090799/photo-timezone-modifier-claude/releases)

每次推送或合併到 `main`，GitHub Actions 會在 Apple Silicon macOS 27 runner 執行完整測試、下載並驗證固定 SHA-256 的 Sony ILCE-7M4 真實 ARW fixture、建置 M 系列 App，成功後自動發布到 Releases。ZIP 解壓縮後，將「相片時區修改器.app」放到「應用程式」即可。固定下載連結提供最新成功發布的版本；測試或建置失敗時保留上一個成功版本。

每個 Release 記錄提交與建置編號，舊版本可保留下載。PR 的建置成品只放在 Actions 的 `PhotoTimezone-macOS` artifact。也可在 Actions 手動執行 `macOS native app`，選擇 `main` 重新建置發布。App 目前使用 ad-hoc 簽章，尚未取得 Apple Developer ID 簽章／公證。

## 建置與測試

Apple Silicon（M 系列）macOS 27+，需 Swift 6.4 工具鏈、CMake 3.20+（`brew install cmake`）與系統 `/usr/bin/perl`。

```bash
./scripts/test.sh
PHOTO_TIMEZONE_STRESS=1 ./scripts/test.sh --filter testThousand
./build.sh
```

成品位於 `dist/相片時區修改器.app`，只包含 arm64 架構並要求 macOS 27.0+。預設是 ad-hoc 簽章，不是 Apple 公證發行版；Intel 與 macOS 26 以下不再列為支援或 CI 驗證平台。

建置時仍驗證 ExifTool 原始套件的 SHA-256；這是供應鏈檢查，不是照片 HASH。內附套件只移除非執行期資源，完整 `lib` 與授權文件保留。

修改 Swift 後要快速檢查能否編譯，先執行 `python3 scripts/prepare-jpegli.py` 與 `./scripts/prepare-jxl.sh` 準備原生編碼器，再執行 `swift build --scratch-path /private/tmp/PhotoTimezone-debug-$UID -c debug --arch arm64`；它不會重新打包或安裝 App。JPEG XL 由腳本下載與核對固定來源版本 0.12.0 後建置；需 Homebrew 依賴 `brew install cmake pkg-config highway brotli little-cms2` 及 Node.js，安裝版內含執行期函式庫。要自己產生可安裝版再執行 `./build.sh`，解壓 `dist/PhotoTimezone-macOS.zip` 後將 App 放進「應用程式」。這樣可把日常修改與完整打包分開，減少不必要的重複建置與等待。推送到 `main` 後 CI 會自行執行完整測試與正式打包；尚未完成的 CI 不代表新版本已可下載。

實作與驗證界線見 [REPAIR_NOTES_3.5.md](REPAIR_NOTES_3.5.md)。舊版資料見 [歷史文件](docs/README-3.4.1-historical.md)，其 HASH 政策不適用於 3.5.0。
