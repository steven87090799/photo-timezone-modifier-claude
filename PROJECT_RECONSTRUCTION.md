# 專案還原說明

本專案的原始碼是從桌面上的「相片_時區修改器_claude.app」內嵌的 Contents/Resources/Scripts/main.scpt 還原而來。

原 App 是 AppleScript droplet；因此 GitHub 主要保存可讀的 .applescript 原始碼與建置腳本，而不是只保存無法直接修改的 App 二進位內容。

## 原生版 3.0

新版以 SwiftUI／Foundation 改寫，原 AppleScript 已移至 legacy/main.applescript 保存。
build.sh 現在建置原生 App「相片時區修改器.app」；不會使用或修改桌面上的舊 App。
原始還原版本仍可在 Git commit bdc9b497959197ee41204a78b00fb9e57c2d2df2 查看。
