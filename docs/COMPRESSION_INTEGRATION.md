# 影像壓縮分頁整合

## 來源與範圍

本分頁以私人 GitHub 專案 `steven87090799/nexpress` 的 `d321ad44f90829d7e54dfd4fa8afcfb3ef5e751a`（NEXPRESS 3.2.1）為來源。`CompressionWeb/` 保留該專案的執行期頁面、Worker、WASM 編碼器、字型、圖示、離線 Service Worker 與 Build ID 驗證；移除 Cloudflare 託管層、開發測試工具及舊的第三方 HEIF 編解碼資產。上方的「影像壓縮」分頁用 `WKWebView` 載入只監聽 `127.0.0.1` 的 App 內建頁面；原有的「相片處理」時區寫入工作不會因此開始重新編碼。

| 原專案頁面／功能 | macOS 分頁中的位置 |
| --- | --- |
| 壓縮：拖放／多選、六種輸出格式、品質、預覽、並行與執行進度 | 影像壓縮 → 壓縮 |
| 單檔結果、並排縮放檢視、下載、全部 ZIP、失敗報告 | COMPRESS 右側結果區 |
| 批次：待處理數量、格式、執行緒與大小估算摘要 | 影像壓縮 → 批次 |
| 設定：目前設定摘要、PWA 狀態、選用 Webhook 與測試 | 影像壓縮 → 設定 |
| 關於：引擎、格式與中繼資料說明、執行中的 Build ID／更新狀態 | 影像壓縮 → 關於 |
| CHANGELOG | 與上游相同，在 COMPRESS 頁左下設計者簽名連點五次開啟 |
| 離線快取、更新提示、深／淺色模式、Worker 狀態 | 壓縮頁設定與狀態區 |

本機頁面不用網際網路即可處理圖片。Webhook 預設關閉；只有使用者設定 URL 並啟用後，才會把輸出檔與摘要送往指定端點。Webhook Token 只存在目前頁面工作階段。遠端 Webhook 應使用 HTTPS；本機 HTTP 可用於開發接收端。服務端仍需允許從本機頁面 origin 發出的跨來源請求。

## 編碼器選擇

「最佳」依畫質、大小、速度、相容性及中繼資料需求而變，沒有單一格式在所有圖片上都最優。這版保留來源專案已調校的實際輸出編碼路徑；300×300 即時預覽使用較快參數，不能當作完整輸出的位元組級預測。

| 格式 | 完整輸出的實作與選擇理由 | 適用情境 |
| --- | --- | --- |
| JPEG | MozJPEG WASM，漸進式、Trellis；高品質改用 4:4:4。jpegli 是值得追蹤的新編碼器，但目前沒有同一批照片的畫質／時間比較與已整合的 WASM、metadata 路徑，因此未以未驗證的新編碼器取代現有流程。 | 最廣泛的分享／服務相容性；可嘗試保留 EXIF／ICC。 |
| PNG | OxiPNG WASM，像素無損；滑桿映射壓縮努力度 0–6，預設最高努力度。 | 圖示、截圖、透明與必須無損的圖片。 |
| WebP | libwebp WASM，`method: 6` 與 sharp YUV；輸出重建 EXIF／ICC 容器。 | 網站用靜態圖片，兼顧體積與普及度。 |
| AVIF | libavif／libaom WASM，`speed: 4`、品質映射 CQ，較高品質時用 4:4:4。 | 願意付出較長編碼時間以壓小照片。 |
| HEIF／HEIC | macOS ImageIO `public.heic` 原生 HEVC，使用 `kCGImageDestinationLossyCompressionQuality`；同一原生路徑處理 HEIC 輸入及預覽。沒有 elheif、kvazaar 或 heic-to。 | Apple 裝置與軟體流程；品質可調。 |
| JPEG XL | libjxl WASM，有損時按尺寸選 effort；品質 100 為像素無損，大圖按記憶體風險降低 effort。 | 可接受格式相容性限制的封存與高品質輸出。 |

參考原始技術文件：[Apple ImageIO destination types](https://developer.apple.com/documentation/imageio/cgimagedestinationcopytypeidentifiers())、[ImageIO 有損品質鍵](https://developer.apple.com/documentation/imageio/kcgimagedestinationlossycompressionquality)、[MozJPEG](https://github.com/mozilla/mozjpeg/blob/master/README.md)、[jpegli](https://github.com/google/jpegli/blob/main/README.md)、[OxiPNG](https://github.com/oxipng/oxipng)、[libwebp](https://github.com/webmproject/libwebp/blob/main/doc/api.md)、[libavif](https://github.com/AOMediaCodec/libavif/blob/main/doc/avifenc.1.md)、[libjxl effort](https://github.com/libjxl/libjxl/blob/main/doc/encode_effort.md)。這些文件說明各編碼器能力，不代表已對所有照片完成跨編碼器主觀畫質比較。

## 色彩、中繼資料與輸入限制

- 來源會經過 WebKit ImageData 的 8 位元 RGBA 像素路徑；輸出不可當成 RAW／HDR／10-bit／增益圖或原始 ICC 的完整保存副本。HEIF 原生輸出以 sRGB 像素編碼。
- JPEG 來源轉 JPEG 可複製既有 EXIF／ICC／XMP APP 區段；轉 WebP 則重組 EXIF／ICCP／標準 XMP chunk。遇到無法安全注入的中繼資料會讓該張失敗，不會回傳一張被剝除資料卻標示成功的圖片。延伸 XMP 不能安全重組為 WebP 時會逐張失敗。
- 非 JPEG 來源的 EXIF／ICC／XMP 尚無完整提取路徑，不能宣稱全部保留。AVIF、HEIF、PNG、JPEG XL 輸出目前不注入來源 EXIF／ICC／XMP；結果卡與處理紀錄會明確顯示不保留或未確認。壓縮流程不提供時區或 GPS 修改入口，也不會在 Worker 內執行舊版的時間改寫。
- 動畫 GIF／APNG／WebP 只處理第一幀，介面會提示。JPEG XL 的品質 100 是解碼後像素無損，並非 JPEG 原始位元流的可逆重封裝；若無損模式的 WASM 工作中止，原流程會明示改用新 Worker 的品質 99 重試。
- 大檔案會佔用 WebKit、Worker 與原生解碼記憶體；服務端限制單次 HEIF 請求本體最多 256 MiB。ZIP 產生時需要額外記憶體。

## 變更與驗證方式

改動 `CompressionWeb/index.html`、`main.js`、`worker.js`、`sw.js` 或其他執行期資產後，在 `CompressionWeb/` 執行：

```sh
npm run generate:build-info
npm run check:build-info
npm run check:syntax
```

接著在專案根目錄執行 `./build.sh`，使用 `dist/PhotoTimezone-macOS-local.zip` 解壓後的 App。ABOUT 的 Build ID 應顯示 `VERIFIED`；離線狀態應在快取完成後顯示 READY。使用非私人測試圖各輸出一張格式並檢查可下載；HEIC 輸入與 HEIF 輸出也應各走一次。這些檢查不取代真實照片的色彩、畫質與中繼資料驗收。
