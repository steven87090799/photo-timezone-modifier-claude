# 原生影像壓縮分頁

## 操作介面

介面採用相片時區修改器的 SwiftUI 風格，上方固定頁籤沿用主程式。左側提供匯入、六種格式、品質／PNG 壓縮努力度、並行數與輸出設定；中間顯示批次清單、逐張進度與總進度；右側顯示原始圖片、預覽或實際輸出、大小及中繼資料結果。說明放在問號懸浮提示及「格式與中繼資料說明」。切換分頁保留清單及結果；離開分頁且沒有工作時釋放引擎，再次進入時重新載入。

1. 加入多張圖片或資料夾，也可拖入。包含子資料夾選項在加入資料夾時生效。
2. 選格式、品質與並行數。選取圖片可產生最長邊 900 px 的快速預覽及約略大小；正式輸出維持完整尺寸。預覽部分編碼參數較快，因此估算不是精確承諾。
3. 開始整批壓縮。可停止尚未完成的工作，已完成結果仍可儲存。
4. 在右側儲存單張，或由下方「儲存全部」和「ZIP」儲存成功的結果。不再提供 CSV 匯出；逐張狀態、容量與錯誤仍可在清單及預覽區查看。整批儲存遇到同名檔會加上序號，不取代原檔。
5. 有失敗時，可在清單上方只顯示失敗，或按下方「重試失敗」。重試使用目前格式與品質，保留其他成功結果。右上角的預覽按鈕可隱藏右側面板，放大清單。
5. 「放大比較」可並排查看原始與壓縮影像。系統無法解碼的輸出仍可儲存，介面明示無法視覺預覽。

Webhook 預設關閉，只有啟用後才傳送壓縮檔及摘要。設定支援 HTTPS，以及 localhost／127.0.0.1 的 HTTP 測試；Bearer Token 僅保留在這次工作階段。保留 NEXPRESS 的 multipart `file`、`metadata`、`X-Nexpress-Batch` 與 JSON 摘要欄位；失敗重試兩次，傳送結果獨立列出。原生 URLSession 不需要瀏覽器 CORS 設定，也不跟隨重新導向。

## 執行引擎與格式

編碼器來自私人專案 `steven87090799/nexpress` 的 `d321ad44f90829d7e54dfd4fa8afcfb3ef5e751a`（3.2.1）。`CompressionWeb` 僅保留編码 Worker、WASM、執行期政策與身分驗證程式。原網頁的外觀、主控制程式、字型、圖示、PWA、Service Worker 與 JSZip 已移除。JPEG 已替換為原生 Jpegli 靜態函式庫，不依賴 WebKit；MozJPEG 的 WASM 與 JS 已移除。WKWebView 只在選用其他壓縮格式時執行不可見的 `engine.html`，本機服務僅監聽 loopback 的隨機連接埠。控制項、檔案匯入、預覽檢視、進度、匯出與 Webhook 均由原生程式提供。

| 格式 | 完整輸出 | 色彩處理 |
| --- | --- | --- |
| JPEG | 原生 Jpegli，普通漸進式 JPEG、自適應量化、高品質 4:4:4（不使用 XYB） | 保留來源 RGB ICC，其他色彩模式轉 sRGB |
| PNG | OxiPNG，像素無損，努力度 0–6 | 保留來源 RGB ICC |
| WebP | libwebp，method 6、sharp YUV | 保留來源 RGB ICC |
| AVIF | libavif／libaom，speed 6、CQ 品質映射 | 明示轉換為 sRGB |
| HEIF／HEIC | macOS ImageIO `public.heic` 原生 HEVC | 保留來源 RGB ICC |
| JPEG XL | 原生 libjxl 0.12.0，品質 100 為解碼後 RGBA 像素無損，依尺寸調整 effort | 保留來源 RGB ICC，並驗證轉換後色彩特性一致 |

HEIF／HEIC 輸入、預覽與輸出都使用 macOS ImageIO，沒有第三方 HEIF 轉換工具。JPEG 預設品質為 86；舊版 MozJPEG 預設 82 會遷移到 86，使用者自訂值會保留。JPEG 品質數字不能直接跨編碼器比較；同一張 24 MP 照片的 Jpegli／MozJPEG 大小與 SSIMULACRA2 實測見 [JPEG 方案比較](JPEG_OPTIONS.md)。Jpegli 編碼器支援 Windows，但此 SwiftUI App 仍為 macOS 專用；固定版本與驗證見 [NATIVE_JPEGLI.md](NATIVE_JPEGLI.md)。JPEG 品質 100 仍是有損，透明輸入轉白底。JPEG XL 品質 100 無損編碼失敗時明確報錯，不會自動改為有損。原生 libjxl 及其執行期函式庫隨 App 一起簽署和封裝，安裝後不依賴 Homebrew 或 JXL WASM。

PNG 品質滑桿控制 OxiPNG 壓縮努力度，使用平方曲線映射到 0–6 級，讓預設品質 86 對應 effort 4，最高品質 100 才使用 effort 6。努力度只影響處理時間與檔案大小，不影響解碼後像素。本次一張 24 MP 照片在 effort 4 與 5 產生相同 SHA-256 的 35.76 MB PNG，實測時間由 295 秒降到 148 秒；這是該照片的結果，不代表每張圖片都會得到相同收益。AVIF 維持 speed 6；本次試驗 speed 8 沒有穩定縮短時間，因此未保留該調整。

## 中繼資料與檔案安全

- ImageIO 解碼轉正後，以 8 位元 RGBA 在來源 RGB 色彩空間編碼，避免 WebKit canvas 先轉 sRGB 再錯標原 ICC。AVIF／JXL 明確先轉 sRGB，輸出回報此轉換。
- 內建 ExifTool 複製一般 EXIF、完整 XMP 封包、IPTC 封包、ICC，並比對來源和輸出中的可讀欄位及 ICC 位元組。既有時區、GPS、日期不做重新指定或平移。方向與尺寸欄位配合轉正後像素更新，舊縮圖與預覽不複製。
- 未保留的欄位逐張回報；RGB 原 ICC 無法一致寫入時，拒絕該張結果，避免錯色。相機私有 MakerNote 及不透明二進位欄位不宣稱逐位元驗證。格式能力不足時不顯示「全部保留」。
- 壓縮不改 `.xmp` sidecar，不重複執行修圖前的時區／GPS 操作。這個頁面的輸入應為修圖後匯出的圖片。
- 高位元／HDR／RAW／增益圖不保證保留，動畫只輸出第一幀，逐張提示。PNG／JXL 的無損指的是解碼後的 8 位元像素，不是原始檔的可逆封裝。
- 來源先複製到專用暫存目錄，複製前後檢查身分；編碼與中繼資料寫入都處理暫存副本。單檔最多 256 MiB，解碼後 RGBA 最多 256 MiB，大圖會降低實際並行數。ZIP 使用系統 ditto 在暫存目錄打包。
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
