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

## 本機驗證與 JPEG 品質校準

2026-10-05 在 Apple Silicon macOS 27 上以同一張 6000×4000 照片比較 3.5.1 MozJPEG 與本分支 Jpegli。SSIMULACRA2 分數愈高代表與來源愈接近；數字是客觀參考，仍不能取代不同場景的 100% 人眼檢查。

| 編碼器與品質 | 輸出大小 | SSIMULACRA2 | 相對舊 MozJPEG 82 |
| --- | ---: | ---: | --- |
| MozJPEG 82（舊版） | 5,158,647 B | 82.5437 | 基準 |
| Jpegli 82 | 4,538,682 B | 78.1903 | 小 12.0%，但畫質分數低 4.35 |
| Jpegli 86 | 5,046,128 B | 83.1975 | 小 2.18%，畫質分數高 0.65 |
| Jpegli 90 | 6,614,089 B | 86.1043 | 大 28.2%，畫質分數高 3.56 |

因此新安裝預設品質為 86；尚未遷移的舊版預設 82 會自動調至 86，舊版自訂品質值則保留。品質 86 在這張照片上比舊版 82 稍小且分數稍高，較符合「檔案小、畫質不明顯下降」的目標。不同照片的最佳點會變動，畫質 100 仍是有損 JPEG。

品質曲線實際輸出大小（82／84／86／88／90）為 4,538,682／4,771,980／5,046,128／5,322,694／6,614,089 bytes。品質 1、49、82、95、100 均由 macOS ImageIO 識別並解碼為標準 `public.jpeg`；來源 Display P3 ICC 逐位元保留。ExifTool 確認輸出為 8 位元、三分量、漸進式 DCT／Huffman JPEG，品質 95 與 100 使用 4:4:4，其餘測試值使用 4:2:0。

功能驗證包含：完整回歸套件 107 個核心測試與 19 個壓縮測試；固定校驗碼 Sony A7 IV ARW 的時區、GPS、備份與還原；兩項 1,000 張壓力測試；桌面 `testjpg` 43 張 JPEG 的副本／影像資料保留、時區與 GPS 批次寫入；六種輸出格式的實際照片壓縮；43 張原始 JPEG 的原生 JPEG XL 批次。原始 43 張照片的雜湊在測試後全部一致。逐張結果與已知限制記錄在本機測試輸出目錄。

壓縮結果已核對日期、EXIF 時區、GPS、XMP 與可支援的 ICC。部分 WebP／AVIF／HEIF／JPEG XL 容器不保留來源 IPTC-IIM 的 Caption、關鍵字與日期欄位，程式會在結果中明示；AVIF 明確轉為 sRGB。PNG 以 OxiPNG effort 4 對 effort 5 比較，這張照片的解碼像素及檔案 SHA-256 完全相同，耗時約由 295 秒降至 148 秒。其他格式的實際處理時間會隨照片與系統負載變動。

## 自行建置

macOS 安裝 CMake（一次）：`brew install cmake`。`./build.sh` 與 `./scripts/test.sh` 自動準備固定版本的原生編碼器；已有相同建置時直接使用快取。

日常只編譯 Swift、不打包安裝：

```bash
python3 scripts/prepare-jpegli.py
swift build --scratch-path /private/tmp/PhotoTimezone-debug-$UID -c debug --arch arm64
```

Windows 編碼器檢查（不建置 SwiftUI App）：安裝 Visual Studio C++、CMake 與 Python，執行 `python scripts/prepare-jpegli.py`。產生的相容性 JPEG 位於 `.build/vendor-jpegli/compatibility`。

完整來源／CMake 快取放系統暫存目錄；專案只留必要的靜態函式庫、授權與少量相容性 fixture，均由 `.gitignore` 排除。授權與固定來源清單會進入 App 的 `JpegliLicenses` 資源目錄。

目前本機封裝會在分支驗證報告中記錄版本、架構、簽章、封裝大小與 SHA-256。CI 尚未執行完成前，不將本機建置視為 GitHub 產物或已發布版本。
