# 相片時區修改器 3.5.0

原生 macOS SwiftUI 工具，支援 JPEG、TIFF、Sony ARW。只有在使用者明確確認後才補寫三個 EXIF 時區欄位或手動新增 GPS；不換算或修改拍攝時間。

## 這版的寫入規則

介面與核心預設一致：處理三個標準 EXIF 欄位，預設僅補缺漏，預設輸出獨立副本。「覆寫所選時區」才會替換既有偏移。

| 時區標籤 | 對應日期（不會修改） |
|---|---|
| `ExifIFD:OffsetTimeOriginal` | `ExifIFD:DateTimeOriginal` |
| `ExifIFD:OffsetTimeDigitized` | `ExifIFD:CreateDate` |
| `ExifIFD:OffsetTime` | `IFD0:ModifyDate` |

所有已讀取的日期與次秒必須在寫入前後相同。缺少的建立或修改日期不會被捏造；非法拍攝日期會被拒絕。固定 UTC 偏移不是城市時區，不會自動推斷夏令時間。

## 效能與安全界線

依使用者選擇，**正式處理流程不再計算整檔、影像、縮圖或 MakerNotes HASH**。仍保留高精度可讀中繼資料比對、檔案身分與時間檢查、候選副本、原檔備份、安全提交與交易紀錄。

**中繼資料相同不能證明影像或未公開私有位元組相同。** Sony 相容模式僅放行明列的位置指標重排，不宣稱 RAW 私有區塊完整性認證。重要照片仍需另一顆磁碟的獨立備份。

ExifTool 在單次工作中重用，定期回收；進度事件有界線，清單排序移到背景並快取；縮圖最多 8 張與 8 MiB。不為側欄強制解碼整張 ARW。單次中繼資料輸出上限 16 MiB，超限不接受部分結果。

## ON1 / Lightroom / Immich / Google 相簿

唯讀診斷 EXIF、內嵌 XMP 與 XMP sidecar 的時間衝突，**不會為了讓軟體顯示相同而偷改拍攝時間或 XMP**。副本模式預設原樣複製同名 `.xmp`、`.on1`、`.acr` 伴隨檔，同名衝突會停止該張照片的發布。

雲端圖庫、編目資料庫或既有 XMP 不一定自動更新。本版不宣稱已在 CI 內啟動 ON1／Lightroom／Immich／Google Photos。ON1 提供 A/B/C/C0 實機驗證流程與自動判讀腳本，見 [ON1 acceptance](docs/ON1_ACCEPTANCE.md)。

## 復原與異常提交

「從原始備份還原」是**整檔還原**，不是僅撤銷時區；還原前會另存當前版本。不會自動刪除你的備份。既有 `_original` 必須能由 PhotoTimezone 的 durable transaction provenance 證明來源，否則自動還原／再次原檔寫入會被拒絕。

發布后的同步錯誤會標記「已發布但未確認」，阻止盲目重試。由「資訊」選單開啟交易復原檢視；人工確認只封存紀錄，不會偷刪檔或自動重試。若 crash 發生在發布前，只有身分、路徑與 UUID 都能對上的 disposable candidate 才會自動清理。診斷頁另提供 Logs／非 provenance 歷史記錄與孤立候選的顯式清理；照片備份只統計、不自動刪除。

## 下載 App

[下載最新版 macOS App](https://github.com/steven87090799/photo-timezone-modifier-claude/releases/latest/download/PhotoTimezone-macOS.zip) · [所有建置版本](https://github.com/steven87090799/photo-timezone-modifier-claude/releases)

每次推送或合併到 `main`，GitHub Actions 會在 Apple Silicon macOS 27 runner 執行完整測試、下載並驗證固定 SHA-256 的 Sony ILCE-7M4 真實 ARW fixture、建置 M 系列 App，成功後自動發布到 Releases。ZIP 解壓縮後，將「相片時區修改器.app」放到「應用程式」即可。固定下載連結提供最新成功發布的版本；測試或建置失敗時保留上一個成功版本。

每個 Release 記錄提交與建置編號，舊版本可保留下載。PR 的建置成品只放在 Actions 的 `PhotoTimezone-macOS` artifact。也可在 Actions 手動執行 `macOS native app`，選擇 `main` 重新建置發布。App 目前使用 ad-hoc 簽章，尚未取得 Apple Developer ID 簽章／公證。

## 建置與測試

macOS 13+，需 Swift 6 工具鏈與系統 `/usr/bin/perl`。

```bash
./scripts/test.sh
PHOTO_TIMEZONE_STRESS=1 ./scripts/test.sh --filter testThousand
./build.sh
```

成品位於 `dist/相片時區修改器.app`，只包含 arm64 架構並要求 macOS 27.0+。預設是 ad-hoc 簽章，不是 Apple 公證發行版；Intel 與 macOS 26 以下不再列為支援或 CI 驗證平台。

建置時仍驗證 ExifTool 原始套件的 SHA-256；這是供應鏈檢查，不是照片 HASH。內附套件只移除非執行期資源，完整 `lib` 與授權文件保留。

實作與驗證界線見 [REPAIR_NOTES_3.5.md](REPAIR_NOTES_3.5.md)。舊版資料見 [歷史文件](docs/README-3.4.1-historical.md)，其 HASH 政策不適用於 3.5.0。
