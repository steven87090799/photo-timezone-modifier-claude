import Foundation

/// Read-only, reusable metadata session for the compression list.
public final class CompressionPhotoReader {
    private let tool: ExifTool
    private let sidecarIndex = SidecarIndex()
    public init(exiftoolURL: URL? = nil) throws {
        tool = ExifTool(url: try exiftoolURL ?? EngineResources.exiftoolURL(), persistent: true)
    }

    /// Compression cannot reconstruct proprietary editing sidecars or infer
    /// whether embedded metadata is newer. Refuse to silently omit the bundle.
    public static func requireEmbeddedMetadataOnly(_ source: URL) throws {
        let sidecars = try SidecarSupport.find(beside: source)
        guard sidecars.isEmpty else {
            throw PhotoError("來源旁有外部中繼資料或修圖檔（\(sidecars.map(\.lastPathComponent).joined(separator: "、"))）。為避免遺失，請先由原修圖軟體匯出已嵌入中繼資料的圖片，再進行壓縮；來源與伴隨檔保持原狀。")
        }
    }
    public func read(_ source: URL) throws -> PhotoMetadata {
        let identity = try FileIdentity.read(source)
        let snapshot = try tool.snapshot(source, strictOffsets: false, forCompression: true)
        var metadata = snapshot.metadata
        if !snapshot.warnings.isEmpty { metadata.compatibilityIssues.append(snapshot.warnings) }
        do {
            for sidecar in try SidecarSupport.find(beside: source, index: sidecarIndex) where sidecar.pathExtension.lowercased() == "xmp" {
                let read = try tool.readSidecar(sidecar)
                metadata.sidecarGPSDetected = metadata.sidecarGPSDetected || read.hasGPS
                metadata.gpsSafetyUncertain = metadata.gpsSafetyUncertain || !read.gpsCheckReliable
            }
        } catch {
            metadata.gpsSafetyUncertain = true
            metadata.compatibilityIssues.append("旁邊的 XMP 無法可靠檢查：\(error.localizedDescription)")
        }
        try identity.verify(source)
        return metadata
    }
}
