import Foundation
import ImageIO
import UniformTypeIdentifiers
import TimezoneCore

/// The encoders currently produce one standard RGB image. Do not accept an
/// input whose additional image data or precision would silently disappear.
enum CompressionValidation {
    static func sourceDepth(_ url: URL, format: CompressionFormat, quality: Int) throws -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw PhotoError("來源影像不完整或無法可靠讀取，已停止輸出。")
        }
        if let identifier = CGImageSourceGetType(source) as String?,
           UTType(identifier)?.conforms(to: .rawImage) == true {
            throw PhotoError("RAW 原始感光資料不能由目前的壓縮流程完整保存；請先以修圖軟體匯出標準 RGB 圖片，並保留 RAW 原件。")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw PhotoError("來源包含動畫或多頁影像，目前無法完整保存所有影格，已停止輸出。")
        }
        let auxiliaryTypes = [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
            kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]
        guard !auxiliaryTypes.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }) else {
            throw PhotoError("來源含 HDR 增益圖、深度圖或人像輔助資料，目前無法完整保存，已停止輸出。")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw PhotoError("來源影像無法完整解碼，已停止輸出。")
        }
        guard image.colorSpace?.model == .rgb else {
            throw PhotoError("此來源不是標準 RGB 色彩，轉換可能改變色彩描述檔或像素，已停止輸出。請由原軟體匯出 RGB 副本並保留原件。")
        }
        guard !image.bitmapInfo.contains(.floatComponents), [8, 16].contains(image.bitsPerComponent) else {
            throw PhotoError("浮點、HDR 或此位元深度的來源無法完整保存，已停止輸出。")
        }
        guard image.bitsPerComponent <= 8 || format == .png || (format == .jxl && quality == 100) else {
            throw PhotoError("來源為 \(image.bitsPerComponent) 位元；所選格式會降低像素精度。請選 PNG 或品質 100 的 JPEG XL，並保留原件。")
        }
        return image.bitsPerComponent
    }

    static func verifyOutput(_ url: URL, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 20000, height <= 20000,
              width <= 256 * 1024 * 1024 / 4 / height,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              width <= 256 * 1024 * 1024 / (4 * max(1, image.bitsPerComponent / 8)) / height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw PhotoError("中繼資料寫入後的影像未通過完整解碼與尺寸驗證，未接受此輸出。")
        }
    }

    /// A successful encoder exit and a decodable container do not prove a
    /// lossless result. Check actual samples again after metadata publication.
    static func verifyLosslessOutput(source: URL, output: URL) throws {
        let original = try CompressionImages.raster(source, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        let encoded = try CompressionImages.raster(output, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        guard original.width == encoded.width, original.height == encoded.height,
              original.bitsPerComponent == encoded.bitsPerComponent,
              original.bytes == encoded.bytes else {
            throw PhotoError("無損輸出的實際像素、透明通道或位元精度與來源不同，未接受此輸出。")
        }
    }
}
