import Foundation

/// Read-only, reusable metadata session for the compression list.
public final class CompressionPhotoReader {
    private let tool: ExifTool
    private let sidecarIndex = SidecarIndex()
    public init(exiftoolURL: URL? = nil) throws {
        tool = ExifTool(url: try exiftoolURL ?? EngineResources.exiftoolURL(), persistent: true)
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
