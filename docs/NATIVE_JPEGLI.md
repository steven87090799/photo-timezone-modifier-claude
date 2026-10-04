# 原生 Jpegli 整合（2026-10-05）

## 決定與相容性

使用者已要求建立分支並替換 JPEG 編碼器；若編碼器本身支援 Windows，就直接替換。此分支為 `codex/native-jpegli`，App 版本 3.6.0，尚未合併或安裝。

Jpegli 是 JPEG **編碼器**，不是新的副檔名或圖片格式。輸出為普通 `.jpg`，8 位元、3 色彩分量的 YCbCr、Progressive DCT、Huffman coding。品質 1–89 採 4:2:0，90–100 採 4:4:4，自適應量化啟用；不使用 XYB、算術編碼、12 位元 JPEG 或 JPEG XL。品質 100 不是無損。透明 PNG 等來源合成白底。

- [Google 官方說明](https://opensource.googleblog.com/2024/04/introducing-jpegli-new-jpeg-coding-library.html) 說明普通 JPEG 解碼器相容性。
- 本次固定 `google/jpegli` 提交 `031a0077f5799a6041004267fc12b956c1f52a20`；其 [Windows MSYS2 CI](https://github.com/google/jpegli/actions/runs/26757054903) 結果為 success，涵蓋 Windows 建置／測試流程。
- 本專案另增加 `Jpegli Windows compatibility` CI：MSVC 建置同一 C bridge，產生品質 1、49、82、95、100 的 JPEG，用 Windows System.Drawing 系統解碼器檢查格式、尺寸及像素。主 CI 呼叫此流程，正式 Release 必須同時通過 macOS 與 Windows 工作。該工作須由 CI 執行；本機 macOS 測試不能代替 Windows 執行結果。
- 因為 Jpegli 編碼器支援兩平台，直接替換 JPEG 路徑，不保留兩套可選編碼器。**現有 SwiftUI App 尚未移植至 Windows。**

## 實作

`NativeJpegli/dependencies.json` 固定 Jpegli、Highway、skcms、libjpeg-turbo 的提交與來源封存 SHA-256。`scripts/prepare-jpegli.py` 下載校驗並建置靜態函式庫，保留授權與依賴清單；不下載預編譯編碼器。CMake／編譯器只在開發或建置時使用，安裝後不需要 Homebrew。

`Sources/JpegliBridge` 提供小型 C API；實作在 `NativeJpegli/bridge.cpp`。每次編碼各自擁有狀態，RGBA 逐列轉 RGB，不額外建立整張 RGB 副本；取消回呼在掃描列與完成後檢查，成功／錯誤／取消均釋放緩衝區。底層錯誤回跳不跨越 C++ 物件析構。可攜檢查同時驗證啟動前取消與掃描列途中取消。

`CompressionJPEG` 使用 ImageIO 解碼轉正，直接呼叫 Jpegli，並用 ImageIO 檢查輸出是可解碼的普通 JPEG。JPEG 不經 HTTP／WASM，不啟動 WebKit；其他五種輸出沿用現有路徑。工作結束後原生像素與編碼緩衝區釋放，沒有常駐 Jpegli 背景程序。

既有中繼資料複製與驗證繼續處理一般 EXIF、完整 XMP、IPTC、ICC，包括已處理好的時區與 GPS；不新增時區／GPS 修改控制。RGB ICC 沿用原值，其他來源色彩模式轉 sRGB。預覽使用最長邊 900 px，正式輸出維持全尺寸；估算不能代替實際大小。

## 本機驗證

2026-10-05 在 Apple Silicon macOS 27、Swift 6.4、Apple Clang 21：

- 9 項 `CompressionTests` 全部通過：六種格式保留中繼資料、多種來源轉 JPEG、六種預覽、並行 JPEG／PNG、單檔及 ZIP、取消與重載、原生 JPEG 不依賴 WebKit、五種品質的標準 JPEG 解碼、透明白底及非法輸入。
- 品質 1／49／82／95／100 皆被 ImageIO 識別為 `public.jpeg` 並解碼；ExifTool 確認 8 位元、3 分量、Progressive DCT／Huffman；各品質來源 Display P3 ICC 逐位元一致。
- 本機真實 6000×4000 修圖匯出 JPEG 在品質 82 產生 4,539,253 bytes；完整 ON1 XMP、拍攝時間／時區及來源 ICC 驗證通過，來源保持不變。
- 3.5.1 MozJPEG 品質 82 同張曾產生 5,159,218 bytes。**兩個編碼器的品質數字不是相同視覺品質，這不是同畫質基準，也不承諾固定壓縮改善百分比。** 此次沿用使用者現有品質設定；可透過實際預覽自行調整。

## 自行建置

macOS 安裝 CMake（一次）：`brew install cmake`。`./build.sh` 與 `./scripts/test.sh` 自動準備固定版本的原生編碼器；已有相同建置時直接使用快取。

日常只編譯 Swift、不打包安裝：

```bash
python3 scripts/prepare-jpegli.py
swift build --scratch-path /private/tmp/PhotoTimezone-debug-$UID -c debug --arch arm64
```

Windows 編碼器檢查（不建置 SwiftUI App）：安裝 Visual Studio C++、CMake 與 Python，執行 `python scripts/prepare-jpegli.py`。產生的相容性 JPEG 位於 `.build/vendor-jpegli/compatibility`。

完整來源／CMake 快取放系統暫存目錄；專案只留必要的靜態函式庫、授權與少量相容性 fixture，均由 `.gitignore` 排除。授權與固定來源清單會進入 App 的 `JpegliLicenses` 資源目錄。

本機分支 ZIP：3.6.0 build 100，11,632,738 bytes；解壓縮後嚴格簽章及 arm64 架構驗證通過，只連結 Apple 系統動態函式庫，無 Homebrew 執行期依賴。SHA-256：`f715c292a707d04e411d4ea005ab53a4b6555723b251d0fdbbd05dad605b926e`。此為本機分支產物，不代表 GitHub CI 已完成或 main 已發布。
