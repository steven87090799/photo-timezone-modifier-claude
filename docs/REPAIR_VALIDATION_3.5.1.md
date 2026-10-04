# 3.5.1 修復與驗證（2026-10-05）

## 已確認並修復的問題

- PNG／WebP／AVIF／HEIF／JPEG XL 編碼後，被時區處理的 JPEG／TIFF／ARW 格式限制錯誤拒絕。壓縮改用獨立的 MIME 格式政策，時區寫入的限制不放寬。
- 逐欄複製 XMP 會漏掉 ON1 等未知私有欄位。改為完整 XMP／IPTC 封包複製；合法 EXIF 位置及容器 Copy 編號變更採受限比對，仍核對重複值、日期、GPS 與 ICC。
- PNG 努力度原本沒有交給實際編碼器。新增固定版本的單執行緒 OxiPNG，滑桿對應努力度 0–6；解碼後的 8 位元像素維持無損。
- 原先啟動相片處理頁就載入 WebKit，工作程序也保留已載入的 WASM。現在按需載入、閒置 15 秒回收 Worker，離開壓縮頁且無工作時釋放引擎。
- macOS 的 listening socket 無法可靠地用原先的阻塞 accept／shutdown 結束。改為非阻塞 DispatchSourceRead；取消後由取消處理器關閉 fd，避免描述符重用競態。
- 匯入不再解碼所有縮圖；清單按需載入並限制快取。實際並行數按像素、格式與系統記憶體估算調低；不是整個程式的硬記憶體上限。
- 儲存位置與暫存結果的差別加入介面提示；CSV 報告不誤標為圖片已儲存。JPEG XL 品質 100 失敗不再偷偷降到有損。
- 同時包含先前的原生副本屬性驗證及分鐘精度 XMP 日期修復。

JPEG 仍使用 MozJPEG，沒有換成 Jpegli；比較與建議見 [JPEG_OPTIONS.md](JPEG_OPTIONS.md)。AVIF 使用 speed 6；JXL effort 隨尺寸調整，以平衡批次耗時與體積。

## 測試結果

Apple Silicon、macOS 27、Swift 6.4，使用內建 ExifTool 13.59。

| 範圍 | 結果 |
| --- | --- |
| TimezoneCore 完整回歸 | 107 項：106 通過、1 項選用真實 JPEG 資料夾測試略過；約 201 秒 |
| 壓縮最終回歸 | 7 項全部通過；約 12.8 秒 |
| 合計 | 114 項：113 通過、1 項略過，0 失敗 |
| 真實 Sony A7 IV ARW | 時區、GPS、備份、還原通過 |
| 1,000 張原檔寫入與備份 | 1,000 份備份驗證，抽樣 10 張還原通過 |
| 1,000 張副本輸出 | 來源 1,000 張保持原狀，首次失敗 0 張 |
| 六種壓縮輸出 | 日期、時區、GPS、私有 XMP；支援保留 RGB ICC 的格式核對原 ICC 位元組 |
| 輸入與操作 | PNG／HEIF／TIFF 輸入、六種預覽、並行輸出、PNG 像素一致、同名輸出、ZIP 解包、取消及重新載入通過 |
| 真實 24MP ON1 JPEG | 來源不變，XMP 私有欄位、日期與時區保留；品質 82 輸出 5,159,218 bytes |
| 服務停止 | listener 物件釋放，停止後不能重新連線 |

測試只對合成／下載 fixture 或來源的暫存副本寫入。使用者照片及輸出沒有提交到 GitHub。可用 `./scripts/test.sh` 重跑；真實照片與壓力測試需要明確設定對應的選用環境變數。

## 原生程式與資源實測

- 原生 UI 能完成 24MP JPEG 壓縮、顯示實際結果與中繼資料、用儲存面板寫出檔案。品質 49 實際輸出 2,283,648 bytes；這不是與新演算法的畫質比較。
- 開發過程中同一壓縮引擎的 24MP 測量：WebContent 峰值約 463.1 MB，Worker 閒置回收後約 18.8 MB。主程序仍有 ImageIO／配置器等記憶體，不能宣稱使用中全部歸零。
- 最終打包版初開相片處理頁：主程序 physical footprint 約 47.4 MB，沒有壓縮 TCP listener。空白壓縮頁主程序約 85 MB，WebContent 約 17 MB；未預載所有 WASM。
- 離開壓縮頁後，舊連接埠拒絕連線；WebContent／Networking 結束。WebKit 的 GPU helper 可短暫保留，與整個應用程式退出分開看待。
- 關閉最後一個視窗後，已核對主程序及其 resource coalition 中的 GPU／WebContent／Networking PID 全數消失；立即及稍後檢查連接埠均拒絕連線。沒有留下 PhotoTimezoneApp 或此專案 ExifTool 工作程序。

以上是特定照片、系統與工作量的實測，未宣稱 CPU／記憶體已達所有情況的理論最佳，也沒有執行 Jpegli 的本機對照基準。

## 打包界線

本機已打包 3.5.1 build 99，ZIP 在 FileProvider 之外解壓後通過 strict codesign 驗證，架構為 arm64。ZIP SHA-256：

`079abd88c8d3e83a4d3db308759992f14d7f58c11ebad997434047b58658b576`

本機測試使用暫存 App，沒有替換 `/Applications` 的已安裝版本。GitHub CI 會以自己的 run number 編號；觸發 CI 不表示遠端建置或 Release 已完成。本次不等待 CI 結果。
