# 原版桌面 App 核對紀錄

2026-09-29 以唯讀方式檢查桌面上的 `相片_時區修改器_claude.app`。它是 AppleScript droplet，不是沒有程式碼的黑盒子：主要邏輯在 `Contents/Resources/Scripts/main.scpt`，可由 macOS `osadecompile` 還原。還原結果與本專案 `legacy/main.applescript` 逐行比較，`diff` 無差異。`.app` 另含 AppleScript droplet 執行器、圖示和 App 資訊，沒有發現其他專案程式碼。這能確認已封裝版本的行為，但不能證明它曾經的開發歷程或某個未提供的新版原始專案。

原版依賴 App 外的 ExifTool；本機現有 `~/.exiftool_portable/exiftool-master` 原始碼宣告版本 13.59，但無法據此證明每一次歷史執行都使用同一版本。原版在找到系統 ExifTool 時會優先用系統版本，否則用可攜版本或下載當時的 `master`。新版固定隨 App 打包 13.59。

## 實際寫入的是哪裡

原版主命令是 `'-OffsetTime*=+08:00' -overwrite_original`；防呆模式加 `-if 'not $OffsetTimeOriginal'`。`OffsetTime*` 是 ExifTool 的萬用標籤名稱，會寫入標準 EXIF `ExifIFD` 的 `OffsetTimeOriginal`、`OffsetTimeDigitized`、`OffsetTime`，不是改 `DateTimeOriginal` 或把相片轉檔。新 App 改成明確的 `-EXIF:OffsetTimeOriginal=…`、`-EXIF:OffsetTimeDigitized=…`、`-EXIF:OffsetTime=…`。用同一張 Sony ARW 的*可丟棄副本*測試，兩種寫法得到相同的三個 `ExifIFD:OffsetTime*` 標籤位置，也產生相同的內部位址重排。因此使用者最近整批失敗的原因**不是時區寫入位置不同**。

原版防呆判斷只看 `OffsetTimeOriginal`：已有此欄位就略過整張，即使另外兩個偏移缺漏。新 App 的「只補缺漏」會逐一保留已有值、補上缺失值；這是刻意修正，不是相同演算法的照搬。

## 功能對照

| 原版能力／行為 | 原生 App 對應與差異 |
| --- | --- |
| 選多張檔案、選資料夾、拖到 App 圖示 | 支援選檔、資料夾、視窗拖放與開啟；可選擇遞迴子資料夾。原版只讀第一層。 |
| ARW、JPG/JPEG、TIF/TIFF | 相同副檔名；寫入前再核對實際格式，RAW 保持 ARW。 |
| 第一張顯示 Make、Model、SerialNumber、LensModel、拍攝／建立時間、OffsetTimeOriginal、ImageSize、FileType、曝光、光圈、ISO、焦距 | 每張都可預覽對應欄位，外加三個偏移、縮圖、檔案大小、搜尋；序號只在照片本身有記錄時顯示。 |
| 批次統計缺少 `OffsetTimeOriginal` | 逐張檢查三個偏移，顯示每張狀態與真實成功／失敗數；不以 `wc -l` 管線成功誤判掃描。 |
| 整點 UTC −12 至 +14 與代表地區 | 保留整點選擇，預設收合 15 分鐘細分；地區僅為例子，不自動推算夏令時間。 |
| 預設只補缺、可強制覆寫 | 保留兩種模式；可先看資訊，寫入前再確認。 |
| 開始與完成時 macOS 通知 | 原生 App 提供預設關閉的通知開關；由使用者開啟並授權後通知，介面仍持續顯示進度。 |
| 一條 Shell 指令批次寫入、`-overwrite_original` | 改為逐張候選檔、驗證、備份／副本、原子提交。較慢但可報逐張結果、取消與重試；不宣稱零風險。 |
| 系統 ExifTool 或即時下載 GitHub master | 改為 App 內附固定版 ExifTool 13.59，建置時驗證 SHA-256，執行時不下載。 |

## Sony 實拍檔測試與 122 張失敗

最近一次使用者批次工作記錄結尾：副本輸出 UTC+10:00，成功 0、失敗 122、略過 0；沒有覆寫來源。失敗主要是 Sony JPEG 的 `MPImage2:MPImageStart` 與 Sony ARW 的預覽、縮圖、RAW strip 等位址／長度欄位變動。從使用者照片只做唯讀分析；所有寫入實驗都在獨立的*可丟棄副本*進行。對測試樣本提取的 JPEG/ARW 縮圖、預覽與 ARW 影像 strip，其 SHA-256 在寫入前後相同；但提取的 Sony MakerNotes 原始區塊 SHA-256 **不同**，即使使用原版萬用標籤寫法也如此。可讀欄位相同不等於未公開的私有資料逐位元相同。

使用者要求「其他中繼資料不變」時，新 App 預設採嚴格模式，拒絕不能證明符合此條件的 Sony 檔；原版沒有逐張比對，會直接寫入。單純按重試不會解決相同相機檔案的結構重排。若要新增明示的 Sony 相容模式，應由使用者決定能否接受*結構與 MakerNotes 位元組可能變動*，並在模式內逐項驗證可讀欄位與影像資料；即使驗證，也不能保證未知私有資料完全不變。原檔替換之前仍需保留可復原備份。

## 速度為什麼不同

原版啟動一次 ExifTool，把所有路徑交給同一命令，直接寫原檔，不備份、不逐張讀回、不驗證影像與非時區資料；若路徑太多也可能碰到系統命令長度限制。新版掃描採最多 48 張一批，但寫入逐張建立與同步候選檔、讀 EXIF、寫入、再讀並比較全部可讀資料、雜湊核對；替換模式另存備份。這些磁碟 I/O 與多次 ExifTool 啟動是主要成本，不是 SwiftUI 畫面天生較慢。

3.3 把每張寫入前後的基本欄位與完整中繼資料讀取合併，減少兩次 ExifTool 啟動；另為長批次加入短期物件釋放與 malloc 記憶體壓力回收。這能改善負擔，但**不會**讓有安全驗證的批次達到原版直接覆寫的速度，也不能把合成小檔的測試速度外推到大量實拍 ARW。
