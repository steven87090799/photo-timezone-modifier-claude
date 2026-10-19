# 3.7.1 原生介面與照片疊合比較

## 介面

- 相片處理與影像壓縮共用「拖入相片或資料夾」按鈕、文字、拖放提示和圓角。
- 使用原生 NavigationSplitView 側欄，移除整個側欄額外疊加的玻璃；保持原生側欄和工具列的系統效果。
- 多個自訂玻璃控制使用 GlassEffectContainer 共用取樣，並使用同心圓角，避免厚背景和多層玻璃遮擋。
- 比較視窗保留影像本身的色彩；僅標籤和分隔線握把使用玻璃。系統「降低透明度」仍受尊重。

## 比較

- 單一畫布，左側原始照片、右側壓縮結果；移動中央分隔線決定顯示範圍。
- 一個縮放控制，最高 1600%；初次開啟自動縮放至完整照片。
- 拖曳照片或使用滾輪平移；兩張影像共用相同尺寸、縮放和位置，避免兩個捲動區失去同步。
- 100% 為影像像素對應螢幕實體像素。100% 以上關閉插值，便於看細節。
- 每張圖只在開啟時解碼一次，拖曳直接重繪；關閉釋放影像。沿用每張 256 MiB 解碼估算界線（8 bytes／pixel），超出範圍明確提示，不偷偷縮圖。
- 無法原尺寸解碼或兩圖顯示尺寸不同時明示原因，不顯示錯誤對齊的比較。

## Apple 文件

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [What’s new in SwiftUI — WWDC26](https://developer.apple.com/videos/play/wwdc2026/269/)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)

玻璃效果由作業系統依背景內容、視窗狀態與輔助使用設定決定，不加入假的光暈或持續動畫，也不修改使用者的系統外觀設定。
