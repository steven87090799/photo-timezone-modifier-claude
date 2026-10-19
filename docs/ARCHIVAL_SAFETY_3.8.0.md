# 3.8.0 長期保存安全審查

日期：2026-10-19。基礎版本：整合後的 `main`（PR #13，`a42f240`）。

## 時區、GPS、EXIF 與還原

- EXIF 拍攝、建立、修改時間及次秒不平移；只寫使用者授權的時區或 GPS。既有 XMP 與 sidecar 只同步授權欄位，未知或衝突結構拒絕寫入。
- 修正「還原只還原照片，沒有還原 XMP」的問題。新交易記錄原始照片與每個 sidecar 備份身分，還原整組第一版備份，並逐位元組核對。重複寫入不會把後來的 sidecar 當成原始版本。
- 缺少或被替換的備份、無法證明原始 sidecar 版本的舊紀錄、後來新增的伴隨檔均阻擋自動還原。發佈失敗保留當前版本備份並嘗試回復，無法確認時留下未完成交易，不報成功。
- 未完成交易也保留 sidecar 路徑，避免另一張共用同名 XMP 的照片繞過保護。改寫硬連結 sidecar 會拒絕；副本輸出保留不同名稱的 hardlink sidecar。
- 已識別 JPEG 影像區段、TIFF／ARW strip／tile 與預覽資料使用有界串流逐位元組比較，不計算照片 HASH。可讀非目標 metadata 及重複標籤另行核對。
- ExifTool `-validate` 的結構診斷不得新增。來源原有的診斷會在處理結果提醒，不會把「未新增」稱作「來源完全無問題」。這是額外的結構檢查，不能證明未公開相機私有格式的全部內容都已被解讀。
- 新增 `OffsetTime*` 時，缺少或低於 2.31 的 EXIF 版本宣告升為 2.31，符合欄位所需版本；較新的版本不降級。還原保留原始版本及整份檔案。
- 改寫原檔前，備份與必要交易紀錄在 macOS 使用 `F_FULLFSYNC` 要求儲存裝置排空快取。裝置若不支援，會停止原檔替換並保留備份；可改用獨立副本。這不能代替裝置斷電或 NAS 故障實機驗證。[Apple fsync 說明](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)。

## 圖片轉檔與壓縮

- 修正 8 位元 PNG 的預乘／反預乘透明通道造成 RGB 四捨五入與透明像素 RGB 清零。完整 PNG 直接傳遞整數樣本，品質 100 的 JPEG XL 沿用整數路徑；兩者完成 metadata 寫入後都再次比較實際像素、alpha 與精度。
- metadata 遺失不再只警告後接受結果。可讀欄位、XMP 命名空間、可抽取的 MakerNotes／縮圖／預覽／IPTC／Comment／不透明資料，以及 ICC 都有保全檢查；容器無法承載就拒絕輸出。
- JPEG 私有 APP／Photoshop 資源、PNG 未知區塊／文字欄位即使不出現在 ExifTool 標籤清單，也會在來源容器檢查時拒絕轉檔，避免被解碼器靜默丟棄。
- JPEG → JPEG／HEIF、HEIF → HEIF 能抽取原始 EXIF 區塊時，整塊逐位元組保留；其他轉換核對 metadata 語意及可抽取區塊，僅容許特定 EXIF 分數量測值的極小換算誤差，不放寬日期、時區、GPS 或 XMP。PNG／TIFF → JPEG 補上必要且原先缺少的 EXIF 宣告，避免產生新的格式結構警告。
- XMP 封包在不改欄位時只容許容器需要的末尾 xpacket 可寫入旗標 `r`／`w` 差異；其餘位元組一致。沒有 IPTC 內容的空區塊與空資料校驗值不要求搬入不支援的容器。PNG → PNG 額外原樣保留支援的 SDR RGB cICP 色彩宣告；無法承載該宣告的跨格式輸出會拒絕。
- 修正有損 JPEG XL 重建 ICC、遺失不影響顏色的原描述欄位問題。各品質改以原始色彩空間編碼，從 JXL 碼流讀回原 ICC 並逐位元組核對；不再只用色彩近似當作完整保留。這可能增加有損 JXL 的檔案大小。
- JPEG 的 JFIF 列印密度不再被編碼器預設值取代；跨格式沒有相同的 EXIF 密度宣告承載時拒絕輸出。
- RAW、動畫、多頁、HDR／增益圖／深度輔助資料，以及會降低位元精度或不支援的色彩排列不會自動轉成不完整版本。有外部 `.xmp`／`.on1`／`.acr` 時也會停止，請先由原修圖軟體匯出整合 metadata 的 RGB 圖片。
- 來源全程保持原狀；正式結果須完整解碼及尺寸核對。輸出保留可安全轉移的檔案日期、權限、ACL、Finder 標籤與一般延伸屬性，格式專用且無法安全轉移的資料會拒絕。
- 單檔、整批、ZIP 都不覆寫既有檔案。保存已驗證結果的檔案身分，輸出時逐位元組讀回並同步。

## 驗證紀錄

原始基線：核心 108 項、壓縮 31 項測試通過。新增回歸涵蓋整組還原／回復、備份遭替換、hardlink／共用 sidecar、metadata 格式限制、原始 XMP、私有命名空間、透明 RGBA、8／16 位元、來源拒絕條件、結構損壞及不可覆寫輸出。

本機驗證環境為 Apple Silicon、macOS 27、Swift 6.4、固定 ExifTool 13.59／libjxl 0.12.0。

| 項目 | 結果 |
| --- | --- |
| 核心全套 | 142 項通過，包含真實 Sony A7 IV ARW 的時區、GPS、備份與還原 |
| 壓縮全套 | 55 項通過；JPEG／HEIF 八種方向、完整 EXIF／MakerNotes／縮圖、完整 ICC、PNG cICP、8／16 位元樣本、私有 XMP／HEIF UUID、JFIF 密度與失敗不覆寫 |
| 千張原檔流程 | 1,000 張合成 JPEG／TIFF＋1 個損壞檔；掃描 3.52 秒、寫入 107.34 秒；核對 1,000 份原始備份，抽取 10 張還原後逐位元組一致 |
| 千張副本流程 | 1,000 張合成 JPEG，90.65 秒；第一輪全部成功、重試 0 次、1,000 份來源不變 |
| 正式封裝 | arm64 release 建置、動態函式庫與 App 簽章、ZIP 解壓後簽章及架構驗證通過 |

千張案例是本機小型合成照片的流程測試，不是 1,000 張真實 RAW、大照片或 NAS 壓力驗收。真實 ARW 是另行下載並以固定 SHA-256 核對的 CC0 測試檔；沒有處理使用者珍藏照片。測試所用雜湊是獨立測試判定，正式照片處理使用串流位元組比較。

重現全套：設定 `PHOTO_TIMEZONE_REAL_ARW_FIXTURE` 後執行 `PHOTO_TIMEZONE_STRESS=0 ./scripts/test.sh`。千張流程：`PHOTO_TIMEZONE_STRESS=1 ./scripts/test.sh --filter testThousand`。打包：`./build.sh`。GitHub CI 另以目前 PR／main 的精確提交執行全套、Windows Jpegli 解碼及正式封裝；結果以對應提交的 Actions 狀態為準。

## 保存邊界

有損輸出不能還原原始像素；PNG／JPEG XL 像素無損也不能重建原始檔封裝。沒有單一測試能承諾所有相機、未來 EXIF 軟體、儲存裝置及斷電情境永久無問題。原件、原始 sidecar 與獨立備份仍應保留；本輪不宣稱已完成 ON1／Lightroom／Immich／Google Photos 的全版本實機往返驗收。
