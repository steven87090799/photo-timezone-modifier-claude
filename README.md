# 相片時區修改器 3.0

SwiftUI 原生 macOS App，為 ARW、JPEG、TIFF 相片補上 EXIF 時區偏移，支援背景處理、逐檔報告、備份與復原。由原本的 AppleScript droplet 改寫；舊版程式保留在 legacy/，新版 App 不會執行舊程式。

## 使用方式

1. 開啟「相片時區修改器.app」，加入相片或資料夾，也可直接拖放。
2. 選擇是否包含子資料夾，按「掃描預覽」，檢查各檔案的 EXIF 與讀取錯誤。
3. 選擇固定 UTC 偏移（預設 +08:00）；提供 −12:00 到 +14:00、每 15 分鐘一格。
4. 預設「補齊缺漏」只寫入缺少的標籤；「覆寫全部」需要確認。
5. 查看成功、略過、失敗、取消的實際數量。可選取個別檔案查看詳細結果並匯出紀錄。

選項是固定 UTC 偏移，不會根據城市、拍攝日期或夏令時間自動換算。同批相片若跨越不同偏移，請分開處理。程式不改動 EXIF 的 DateTimeOriginal、CreateDate、ModifyDate，寫入後會重新讀取確認。

## 備份與復原

- 每張相片第一次寫入會保留同目錄的「原檔名_original」，不使用 -overwrite_original。
- 再次寫入時，既有 _original 會保留；它代表最早的那份原始備份，不是上一次修改。
- 「從原始備份還原」會將 _original 還原成原檔，並消耗該 _original 檔案。
- 還原前先另外保留當前版本為「原檔名.before-restore-UUID.backup」，再用 SHA-256 驗證還原後檔案與備份完全一致。
- .backup 與 _original 不會被當成相片重新掃描。請保留足夠磁碟空間：首次寫入需要原始備份與寫入暫存；還原會另存目前版本。
- 若原檔遺失但 _original 還在，掃描會顯示可還原的遺失檔案；還原會重建原檔並保留該備份。
- 檔案系統修改時間以 ExifTool 的 -P 保留。這不等於保證所有檔案系統建立時間、Finder 自訂屬性都不變。

## 穩定性

- 直接使用 FileManager 掃描資料夾，無需控制 Finder。跳過隱藏檔、套件與符號連結；重複路徑只處理一次。
- 檔案在背景逐張處理，每個指令只傳入一個路徑，沒有整批路徑串接或 Shell 展開。
- 每張相片都獨立檢查，第一張損壞不會中止其他相片。格式依實際內容再驗證。
- 直接解析 ExifTool JSON、退出狀態與錯誤訊息；警告會保留在每張相片的結果。
- 取消會完成正在處理的相片，再略過後續工作；不強制中斷正在寫入的 ExifTool。單一大型檔案或慢速磁碟可能需要等候。
- 寫入前的 ExifTool 讀取可取消，單張讀取上限 120 秒；寫入本身不會逾時強殺。非標準位置或重複出現的時區標籤會報錯並保留原檔。
- 同一使用者的多個 App 副本不允許同時執行處理工作；其他軟體修改同一檔案不在此鎖定範圍。
- 紀錄逐檔寫入本機 ~/Library/Application Support/PhotoTimezone/Logs/，包含檔案路徑與中繼資料，不會上傳。若紀錄無法寫入，後續工作會停止。

## 建置與測試

需要 macOS 13+、Swift 5.9+（Xcode 或相容的 Command Line Tools）與 /usr/bin/perl。專案沒有線上 Swift 套件依賴。

    ./build.sh

建置結果位於 dist/相片時區修改器.app，架構為本機架構。Apple Silicon 與 Intel 通用版：

    ./build.sh --universal

建置先驗證 vendor/ 中 ExifTool 13.59 的 SHA-256，然後將完整引擎與授權文件包入 App；使用者執行 App 不需下載引擎，也不會自動採用 Homebrew 或舊版可攜引擎。

    ./scripts/test.sh

測試使用 Swift Testing（需要 Swift 6+ 與相容的 macOS／SDK），使用自動產生的小型 JPEG／TIFF，不修改使用者相片。另可透過 TEST_EXIFTOOL_PATH 指定測試引擎路徑，但版本仍須吻合。原生 App 可直接以 Package.swift 在 Xcode 開啟編輯；直接 swift run 不包含 App bundle 的 ExifTool 資源，完整使用請透過 build.sh。

目前建置採本機 ad-hoc 簽章，尚未以 Developer ID 簽署或送 Apple 公證。正式散布到其他電腦前需要完成該發行流程。系統 Perl 的可用性會在啟動處理時檢查。

## 專案結構

- Sources/PhotoTimezoneApp/：SwiftUI 介面、進度、拖放、選檔與報告。
- Sources/TimezoneCore/：檔案探索、背景工作、ExifTool、備份與復原。
- Tests/TimezoneCoreTests/：單元與真實 ExifTool 整合測試。
- app/Info.plist：原生 App 資訊與文件類型。
- vendor/：固定版 ExifTool 原始碼封存檔、來源 commit 與 SHA-256。
- legacy/：原 AppleScript 歷史版本；僅供參考。

第三方授權見 THIRD_PARTY_NOTICES.md 與 App 資源內的 ExifTool 文件。

已完成的測試與尚未驗證的範圍見 [VALIDATION.md](VALIDATION.md)。
