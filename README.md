# 相片_時區修改器_claude

macOS AppleScript 應用程式：為相片補上 EXIF 時區偏移標籤，方便 Immich、Apple Photos 等服務正確排序。

## 功能

- 可選取單張、多張相片或整個資料夾。
- 支援拖放檔案或資料夾到 App 圖示。
- 支援 .ARW、.JPG、.JPEG、.TIF、.TIFF。
- 先顯示首張相片的 EXIF 資訊，並統計缺少時區標籤的檔案。
- 預設防呆模式只補上缺少時區的相片；也可選擇強制覆寫全部檔案。
- 只寫入 OffsetTime* 時區偏移標籤，不修改 DateTimeOriginal。
- 系統已安裝 ExifTool 時直接使用；否則首次執行會將 ExifTool 下載到使用者家目錄的 .exiftool_portable。

## 建置

需要 macOS 內建的 AppleScript 工具 osacompile。執行：

    ./build.sh

完成後會在 dist/相片_時區修改器_claude.app 產生可執行的 App。也可以直接雙擊 App，或將相片／資料夾拖到 App 圖示上。

## 原始碼

主要程式位於 src/main.applescript。此 repository 是從桌面上的已編譯 App 還原出的可維護版本，方便之後修改與重新建置。

## 注意事項

第一次使用若找不到 ExifTool，程式會從 ExifTool GitHub 專案下載約 15 MB 的核心引擎。執行寫入前請確認相片已有備份；強制覆寫模式會直接更新已有的時區標籤。
