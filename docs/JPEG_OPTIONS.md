# JPEG 編碼方案與實際照片比較（2026-10-05）

## 選擇

本分支將 3.5.1 的 MozJPEG 換為原生 Jpegli。輸出仍是一般 `.jpg`，可由標準 JPEG 解碼器開啟；不使用 JPEG XL 副檔名、XYB 或非標準解碼方式。Jpegli 原始碼也有 Windows 建置支援；專案 Windows 相容性工作會由 PR CI 實際執行。這個 SwiftUI 桌面程式本身仍只支援 macOS。

## 同一張 24 MP 照片的實測

| 編碼器與品質 | 輸出大小 | SSIMULACRA2 | 相對 MozJPEG 82 |
| --- | ---: | ---: | --- |
| MozJPEG 82 | 5,158,647 B | 82.5437 | 基準 |
| Jpegli 82 | 4,538,682 B | 78.1903 | 小 12.0%，分數低 4.35 |
| Jpegli 86 | 5,046,128 B | 83.1975 | 小 2.18%，分數高 0.65 |
| Jpegli 90 | 6,614,089 B | 86.1043 | 大 28.2%，分數高 3.56 |

品質分數愈高代表失真較少，但主觀觀感會受人像、細節、噪點與顯示比例影響。這組結果表示品質數字不能跨編碼器照抄：Jpegli 82 雖更小，畫質下降較明顯；本程式採 Jpegli 86 作為預設，讓實測畫質至少貼近舊版 MozJPEG 82，同時略小。舊版預設 82 會遷移到 86；舊版自訂值維持原值。預覽可再依每張照片調整。

Jpegli 的普通 JPEG 相容性已在 macOS 用 ImageIO 驗證；本地輸出確認為 8 位元、三分量、漸進式 DCT／Huffman。上游固定版本的 Windows CI 已通過；本分支新增 MSVC／Windows 系統解碼驗證，需等 PR CI 回報後才能確認本專案 Windows 工作也通過。macOS App 不能因此在 Windows 執行。

完整實測表、畫質曲線、六種壓縮格式及時區／GPS 驗證，見本機 `testjpg/Jpegli-Project-FullTest-20261005/reports/full-test-report.md`。
