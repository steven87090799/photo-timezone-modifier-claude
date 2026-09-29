# 歷史版本

main.applescript 為從原始桌面 App 還原出的 v2.1 歷史程式，保留作比較用途。
2026-09-29 再次對桌面 `相片_時區修改器_claude.app/Contents/Resources/Scripts/main.scpt`
執行 `osadecompile`，與此檔逐行 `diff` 無差異；核對詳情見專案根目錄 `ORIGINAL_AUDIT.md`。
它仍含舊版的覆寫原檔、執行時下載 master、Shell 長指令等行為；
新版 build.sh 與原生 App 均不會編譯或執行這份程式。
