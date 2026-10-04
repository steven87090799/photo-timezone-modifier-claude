# JPEG 編碼方案比較（2026-10-04）

## 建議與目前決定

**建議下一階段優先評估原生 arm64 Jpegli，保留 MozJPEG 作為比較基準。** 你的用途是修圖軟體匯出後的照片壓縮，需要普通 JPEG 相容性、較好的畫質／體積比例，也在意 CPU 與記憶體。Jpegli 是最有根據的替換候選；不能只因為它較新就認定所有照片都較好。

**3.5.1 修復版仍使用原有 MozJPEG，沒有更換 JPEG 演算法。** 演算法替換等你決定。本次改動是輸出驗證、XMP／ICC 保留、引擎按需啟動及閒置回收；PNG 努力度原本沒有生效，已接上真正的 OxiPNG。

## 比較

| 方案 | 優點 | 缺點／限制 | 適合此程式的角色 |
|---|---|---|---|
| 現有 MozJPEG（WASM） | 普通 JPEG 相容性；漸進式、Huffman 最佳化與 Trellis；已整合並驗證中繼資料 | 壓縮率最佳化需要 CPU；像素跨 ImageIO／HTTP／WASM，會有額外緩衝區；品質 100 仍不是無損 | 本次保留的正式方案 |
| 原生 arm64 MozJPEG | 同一編碼方法；可用原生 SIMD，減少 WebKit 和像素傳輸開銷 | 需新增原生編碼 API、供應鏈固定版本與簽章；實際改善需測量 | 改善效能但保留現有演算法的選項 |
| 原生 arm64 Jpegli | 標準 JPEG 相容；自適應量化、不同量化矩陣及更精確的計算；有高品質照片的主觀評測證據 | 相同品質數字不等於相同畫質；需校準滑桿；此 Mac 的耗時與記憶體尚未量測；新增原生依賴與維護成本 | **畫質／體積優先的首選替換候選** |
| 原生 libjpeg-turbo | SIMD、可直接使用 RGBX 緩衝區；以速度為主要目標，容易做低 CPU 的快速模式 | 壓縮體積未必及 MozJPEG／Jpegli；不能拿與 libjpeg 的速度比當作此程式的收益 | 若你優先要最快、最低耗時，可考慮另設快速模式 |
| macOS ImageIO JPEG | 已有系統依賴；整合及維護簡單；不需 WebKit 編 JPEG | 系統不公開完整調校細節；目前沒有此專案的同畫質體積比較；不能保證檔案最小 | 低依賴的快速方案候選 |
| Guetzli | 高品質 JPEG 的感知壓縮 | 專案已封存；官方估計每百萬像素約 300 MB、約一分鐘 CPU；假設 sRGB gamma 2.2，忽略原 ICC；不適合大型批次 | 不建議加入這個程式 |

MozJPEG 功能來自 [Mozilla 官方文件](https://github.com/mozilla/mozjpeg#features)；Jpegli 的原理與介面見 [Google 官方原始碼](https://github.com/google/jpegli)。libjpeg-turbo 的 SIMD 與緩衝區 API 見 [官方 README](https://github.com/libjpeg-turbo/libjpeg-turbo#background)。Guetzli 的資源與色彩限制見 [官方使用說明](https://github.com/google/guetzli#using)。

## Jpegli 的證據如何解讀

開發者的 [主觀評測研究](https://arxiv.org/abs/2403.18589) 在接近 libjpeg-turbo 品質 95 的設定中，Jpegli 使用 2.8 bits/pixel、MozJPEG 使用 3.5 bits/pixel，Jpegli 仍有約 54% 的偏好率。此組比較的 Jpegli 位元率比 MozJPEG 低約 20%。這是研究照片與特定品質區間的結果，**不是你的所有照片都能再縮小 20%**，也不是品質 49 的直接比較。

[Google 的發表文章](https://opensource.googleblog.com/2024/04/introducing-jpegli-new-jpeg-coding-library.html) 提到約 35% 的高品質壓縮改善；其基準與比較條件不能直接套用到目前的 MozJPEG。新方案不應用這個百分比當 UI 承諾。

## 若你決定更換，建議的驗收方式

1. 使用普通 RGB／YCbCr JPEG，預設不使用 Jpegli 的 XYB 模式。XYB 需要不同 ICC，與「盡量保留原 RGB ICC」的工作流程不相同。
2. 用代表性照片涵蓋人像、樹葉、夜景噪點、細字、漸層，以及 sRGB／Display P3。原檔只讀，測試產物放入獨立資料夾。
3. 以相近視覺品質比較；用 SSIMULACRA2 與人工 100% 檢視，不能只比較同樣的品質 82。Jpegli 官方也提供 [評測方法](https://github.com/google/jpegli/blob/main/doc/benchmarking.md)。
4. 同時量測檔案大小、每張編碼時間、主程序與輔助程序的記憶體、批次取消、EXIF 日期／GPS／完整 XMP／ICC 的讀回結果。
5. 校準品質滑桿後再決定預設。若沒有穩定收益，保留 MozJPEG；若收益只在高品質，應明示模式適用範圍。

以上為官方研究與本專案實作分析；本次沒有執行原生 Jpegli 與 MozJPEG 的本機對照基準，也沒有安裝或替換新 JPEG 編碼器。
