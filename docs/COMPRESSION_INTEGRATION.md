# 原生影像壓縮分頁

## 操作介面

介面採用相片時區修改器的 SwiftUI 風格，上方固定頁籤沿用主程式。左側提供匯入、六種格式、品質／PNG 壓縮努力度、並行數與輸出設定；中間顯示批次清單、逐張進度與總進度；右側顯示原始圖片、預覽或實際輸出、大小及中繼資料結果。說明放在問號懸浮提示及「格式與中繼資料說明」。切換分頁保留清單及結果；離開分頁且沒有工作時釋放引擎，再次進入時重新載入。

1. 加入多張圖片或資料夾，也可拖入。包含子資料夾選項在加入資料夾時生效。
2. 選格式、品質與並行數；RAW 另選 Apple RAW 8／9。選取圖片會產生完整影像輸出，預覽顯示其縮圖與實際檔案大小；來源與設定未變時，批次會重用結果。
3. 開始整批壓縮。可停止尚未完成的工作，已完成結果仍可儲存。
4. 在右側儲存單張，或由下方「儲存全部」和「ZIP」儲存成功的結果。不再提供 CSV 匯出；逐張狀態、容量與錯誤仍可在清單及預覽區查看。遇到重複名稱或既有檔案會停止儲存，請改選目的地；不自動改名或覆寫。
5. 有失敗時，可在清單上方只顯示失敗，或按下方「重試失敗」。重試使用目前格式與品質，保留其他成功結果。右上角的預覽按鈕可隱藏右側面板，放大清單。
6. 「放大比較」可用同一畫布的分隔線查看原始與壓縮影像。正式輸出必須通過完整解碼與尺寸檢查，無法確認的結果不接受儲存。

Webhook 預設關閉，只有啟用後才傳送壓縮檔及摘要。設定支援 HTTPS，以及 localhost／127.0.0.1 的 HTTP 測試；Bearer Token 僅保留在這次工作階段。保留 NEXPRESS 的 multipart `file`、`metadata`、`X-Nexpress-Batch` 與 JSON 摘要欄位；失敗重試兩次，傳送結果獨立列出。原生 URLSession 不需要瀏覽器 CORS 設定，也不跟隨重新導向。

## 執行引擎與格式

### RAW 本機驗證（2026-10-27）

Sony ILCE-6000 的 6000 × 4000 ARW 測試複本已完成 Apple RAW 8／9 各六種完整尺寸輸出，逐張核對日期、時區、GPS、原件位元組，以及 PNG／JPEG XL 100 的顯影後像素。額外方向測試發現 Apple 解碼器可能採用預覽 IFD 的方向，因此明確讀取主要 IFD0 方向並設定 `CIRAWFilter.orientation`；方向 1／3／6／8 在正規化前均已另行驗證。

最後重跑的 RAW suite 為 7 項通過（41.767 秒），包含兩版本各六種小尺寸輸出、方向、版本不回退、設定與預覽隔離、取消，以及 PNG／AVIF 的中繼資料與 RGB 色塊驗證。核心回歸 143 項通過，其他既有壓縮／匯出回歸案例通過；完整尺寸矩陣已另行執行，沒有在最後小尺寸回歸重複執行。Sony A7 IV 的下載用縮小 RAW 樣本在本機只列出 RAW 8 支援，不能以相機型號清單推定該檔案支援 RAW 9。這些是本機驗證，不代表 GitHub CI 或所有相機／RAW 壓縮模式驗收。

### 編碼器

編碼器來自私人專案 `steven87090799/nexpress` 的 `d321ad44f90829d7e54dfd4fa8afcfb3ef5e751a`（3.2.1）。`CompressionWeb` 僅保留編码 Worker、WASM、執行期政策與身分驗證程式。原網頁的外觀、主控制程式、字型、圖示、PWA、Service Worker 與 JSZip 已移除。JPEG 已替換為原生 Jpegli 靜態函式庫，不依賴 WebKit；MozJPEG 的 WASM 與 JS 已移除。WKWebView 只在選用其他壓縮格式時執行不可見的 `engine.html`，本機服務僅監聽 loopback 的隨機連接埠。控制項、檔案匯入、預覽檢視、進度、匯出與 Webhook 均由原生程式提供。

| 格式 | 完整輸出 | 色彩處理 |
| --- | --- | --- |
| JPEG | 原生 Jpegli，普通漸進式 JPEG、自適應量化、高品質 4:4:4（不使用 XYB） | 保留來源 RGB ICC；正式輸出拒絕非 RGB 來源 |
| PNG | OxiPNG，像素無損，努力度 0–6 | 保留來源 RGB ICC |
| WebP | libwebp，method 6、sharp YUV | 保留來源 RGB ICC |
| AVIF | libavif／libaom，speed 6、CQ 品質映射 | 明示轉換為 sRGB |
| HEIF／HEIC | macOS ImageIO `public.heic` 原生 HEVC | 保留來源 RGB ICC |
| JPEG XL | 原生 libjxl 0.12.0，品質 100 為解碼後 RGBA 像素無損，依尺寸調整 effort | 各品質均在原始色彩空間編碼，逐位元組核對原始 ICC |

HEIF／HEIC 輸入、預覽與輸出都使用 macOS ImageIO，沒有第三方 HEIF 轉換工具。JPEG 預設品質為 86；舊版 MozJPEG 預設 82 會遷移到 86，使用者自訂值會保留。JPEG 品質數字不能直接跨編碼器比較；同一張 24 MP 照片的 Jpegli／MozJPEG 大小與 SSIMULACRA2 實測見 [JPEG 方案比較](JPEG_OPTIONS.md)。Jpegli 編碼器支援 Windows，但此 SwiftUI App 仍為 macOS 專用；固定版本與驗證見 [NATIVE_JPEGLI.md](NATIVE_JPEGLI.md)。JPEG 品質 100 仍是有損，透明輸入轉白底。JPEG XL 品質 100 無損編碼失敗時明確報錯，不會自動改為有損。原生 libjxl 及其執行期函式庫隨 App 一起簽署和封裝，安裝後不依賴 Homebrew 或 JXL WASM。

PNG 品質滑桿控制 OxiPNG 壓縮努力度，使用平方曲線映射到 0–6 級，讓預設品質 86 對應 effort 4，最高品質 100 才使用 effort 6。努力度只影響處理時間與檔案大小，不影響解碼後像素。本次一張 24 MP 照片在 effort 4 與 5 產生相同 SHA-256 的 35.76 MB PNG，實測時間由 295 秒降到 148 秒；這是該照片的結果，不代表每張圖片都會得到相同收益。AVIF 維持 speed 6；本次試驗 speed 8 沒有穩定縮短時間，因此未保留該調整。

## 中繼資料與檔案安全

- 支援單張標準 RGB 影像。PNG 與品質 100 的 JPEG XL 直接保存支援的 8／16 位元整數樣本，包含透明像素中的 RGB，完成後再次比較實際解碼樣本。其他格式仍屬有損；JPEG 的透明像素會轉為白底。
- 內建 ExifTool 複製 EXIF、XMP 封包、IPTC、ICC、縮圖與預覽，並核對可讀欄位和可抽取的原始區塊。JPEG → JPEG／HEIF、HEIF → HEIF 的完整 EXIF 區塊逐位元組驗證；其他轉換核對欄位與可抽取區塊，並補足 JPEG 必要的缺漏宣告。既有時區、GPS、日期不重新指定或平移；需要轉正的格式僅更新對應的標準方向與尺寸欄位，私有命名空間中的同名欄位不會略過。
- 無須修改 XMP 欄位時，封包內容逐位元組一致；僅容許容器要求的末尾 xpacket 可寫入旗標 `r`／`w` 差異。沒有 IPTC 資料時的空區塊與空資料校驗欄位屬於封裝資訊，不要求轉入不支援 IPTC 的容器。PNG → PNG 額外保留支援的 SDR RGB cICP 原始區塊；帶 cICP 的 PNG 跨格式轉換、未知區塊或 HDR 宣告會停止，避免失去原色彩宣告。
- JPEG 的 JFIF 列印密度會保留；跨格式若無法由相同的 EXIF 密度宣告承載，就停止輸出。JPEG XL 各品質都保留完整 ICC，包含不影響顏色的描述欄位；此保全設定可能增加有損 JXL 的大小，不把「顏色近似」當成原 ICC 完整保留。
- 無法保存的 metadata、原始區塊或來源 ICC 會拒絕該張輸出，並具名說明；不再只顯示遺失提示卻標為成功。IPTC-IIM 等資料不是每個容器都能容納，請選可保存來源內容的格式。AVIF 目前的 sRGB 編碼流程不能保留有嵌入 ICC 的來源時會停止。
- 同名 `.xmp`、`.on1`、`.acr`（含 `photo.jpg.xmp`）屬於照片的一部分；目前無法完整整合它們，因此壓縮會停止，請先由原修圖軟體匯出已嵌入中繼資料的圖片。來源和伴隨檔保持原狀。
- RAW 自 3.9.0 起透過 `CIRAWFilter` 明確選擇 Apple RAW 8／9（含 DNG 對應版本），顯影為 sRGB TIFF 後交給上述六種編碼器。PNG／JPEG XL 100 使用 16 位元，其他格式 8 位元；先複製、核對標準拍攝資訊與時區／GPS，再沿用 RGB 輸出的嚴格保留與驗證。RAW 私有資料與修圖設定只留在原件。比較畫布使用同次顯影的 TIFF，避免使用相機預覽或另一版本解碼。RAW 批次一次一張，不套用 Lightroom sidecar；伴隨檔仍會阻止自動輸出。
- 動畫、多頁、HDR／增益圖／深度或人像輔助資料、非 RGB、浮點來源均拒絕自動降級；一般 16 位元整數圖片轉成不支援該精度的格式也會停止。PNG／JPEG XL 的像素無損不是原始 RAW、原始檔封裝或有損 JPEG 碼流的可逆保存。
- 來源先複製到專用暫存目錄，複製前後核對身分與位元組；編碼和中繼資料寫入都處理暫存副本。完成後核對來源仍未變、輸出可完整解碼、尺寸與 metadata 正確，並固定已驗證輸出的身分。單檔最多 256 MiB，解碼後 RGBA 最多 256 MiB，大圖降低實際並行數。
- 保留可安全轉移的檔案日期、權限、Finder 標籤及一般延伸屬性；遇到無法安全搬移的資源分支或來源格式專用屬性會停止。輸出一律建立新檔，不覆寫既有照片；儲存後再次逐位元組讀回。ZIP 保留檔案屬性並檢查封裝。
- 關閉／結束程式會阻擋尚在匯入、壓縮或輸出的工作；需先停止或等候完成。

## 自行編譯

修改執行期 JavaScript 後先執行：

```sh
cd CompressionWeb
npm run generate:build-info
npm run check:build-info
npm run check:syntax
cd ..
```

日常修改可用 `swift build --scratch-path /private/tmp/PhotoTimezone-debug-$UID -c debug --arch arm64` 快速確認編譯；需要可安裝 App 時執行 `./build.sh`，使用 `dist/PhotoTimezone-macOS.zip`。這是實際原生介面，不再使用瀏覽器模擬外觀。上傳 `main` 後 CI 會自行打包，不必反覆要求 AI 編譯或等待。
