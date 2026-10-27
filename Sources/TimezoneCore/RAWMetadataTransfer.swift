import Foundation

/// A developed image is a derivative, not a RAW archive. Copy only standard
/// photographic metadata; never transplant RAW layout, camera calibration,
/// embedded sensor previews, MakerNotes, or editing recipes into RGB images.
public enum RAWMetadataTransfer {
    public static let extensions: Set<String> = ["arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "raf",
        "rw2", "rwl", "orf", "ori", "pef", "ptx", "dng", "3fr", "fff", "iiq", "mos", "mrw", "raw", "srw", "x3f", "kdc", "dcr", "erf"]

    /// RAW decoders can prefer a preview IFD's orientation. Use the main
    /// photo's IFD0 when present; thumbnails may legitimately differ.
    public static func orientation(_ source: URL, exiftoolURL: URL,
                                   cancellation: CancellationToken) throws -> Int? {
        let read = try ExifTool(url: exiftoolURL).execute(["-s3", "-n", "-a", "-IFD0:Orientation", source.path],
            timeout: 120, cancellation: cancellation)
        guard read.status == 0, read.stderr.isEmpty else { throw PhotoError("RAW 主要影像方向無法可靠讀取。") }
        let values = Set(String(decoding: read.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
        if values.isEmpty { return nil }
        guard values.count == 1, let text = values.first, let value = Int(text), (1...8).contains(value) else {
            throw PhotoError("RAW 主要影像方向無效或互相衝突。")
        }
        return value
    }
    private static let photoTags: Set<String> = [
        "ImageDescription", "Make", "Model", "Artist", "Copyright", "ModifyDate",
        "DateTimeOriginal", "CreateDate", "SubSecTime", "SubSecTimeOriginal", "SubSecTimeDigitized",
        "OffsetTime", "OffsetTimeOriginal", "OffsetTimeDigitized", "ExposureTime", "FNumber",
        "ExposureProgram", "ISO", "SensitivityType", "StandardOutputSensitivity", "RecommendedExposureIndex",
        "ShutterSpeedValue", "ApertureValue", "BrightnessValue", "ExposureCompensation", "MaxApertureValue",
        "SubjectDistance", "MeteringMode", "LightSource", "Flash", "FocalLength", "ExposureMode",
        "WhiteBalance", "DigitalZoomRatio", "FocalLengthIn35mmFormat", "SceneCaptureType", "GainControl",
        "Contrast", "Saturation", "Sharpness", "SubjectDistanceRange", "CameraOwnerName", "BodySerialNumber",
        "SerialNumber", "LensInfo", "LensMake", "LensModel", "LensSerialNumber", "UserComment", "ImageUniqueID"
    ]

    static func includes(_ key: String) -> Bool {
        let parts = MetadataVerifier.canonicalCopyKey(key).split(separator: ":")
        guard parts.count == 2 else { return false }
        let group = String(parts[0]), tag = String(parts[1])
        if group == "GPS" { return true }
        if ["IFD0", "ExifIFD"].contains(group) { return photoTags.contains(tag) }
        if ["XMP-dc", "XMP-xmpRights"].contains(group) { return true }
        if group == "XMP-xmp" { return ["CreateDate", "ModifyDate", "MetadataDate", "Rating", "Label"].contains(tag) }
        if ["XMP-exif", "XMP-exifEX", "XMP-tiff", "XMP-aux"].contains(group) {
            return photoTags.contains(tag) || tag.hasPrefix("GPS")
        }
        if group == "XMP-photoshop" {
            return ["DateCreated", "Headline", "CaptionWriter", "Credit", "Source", "Instructions", "City", "State", "Country", "CountryCode", "AuthorsPosition"].contains(tag)
        }
        return false
    }

    public static func prepare(source: URL, developed: URL, width: Int, height: Int,
                               exiftoolURL: URL, cancellation: CancellationToken) throws {
        let pinned = try FileIdentity.read(source)
        let tool = ExifTool(url: exiftoolURL, persistent: true)
        let before = try tool.snapshot(source, cancellation: cancellation, strictOffsets: false, forCompression: true)
        let selected = before.embeddedTags.filter { includes($0.key) }
        let tags = Set(selected.keys.map(MetadataVerifier.canonicalCopyKey)).sorted()
        let arguments = ["-overwrite_original", "-n", "-TagsFromFile", source.path] + tags.map { "-\($0)" } + [
            "-IFD0:Orientation#=1", "-ExifIFD:ColorSpace#=1", "-ExifIFD:ExifImageWidth=\(width)",
            "-ExifIFD:ExifImageHeight=\(height)", developed.path]
        let write = try tool.execute(arguments, timeout: 120, cancellation: cancellation)
        guard write.status == 0, write.stderr.isEmpty else {
            throw PhotoError("RAW 標準拍攝資訊無法安全複製：\(write.text) \(write.stderr)")
        }
        let after = try tool.snapshot(developed, cancellation: cancellation, strictOffsets: false, forCompression: true)
        let expected = Dictionary(grouping: selected, by: { CompressionMetadataTransfer.comparisonKey($0.key) })
        let actual = Dictionary(grouping: after.embeddedTags, by: { CompressionMetadataTransfer.comparisonKey($0.key) })
        let missing = expected.keys.sorted().filter {
            !CompressionMetadataTransfer.metadataValuesMatch(key: $0, expected[$0]!.map(\.value), actual[$0]?.map(\.value) ?? [])
        }
        guard missing.isEmpty else { throw PhotoError("RAW 拍攝資訊、時區或 GPS 核對失敗：\(missing.joined(separator: "、"))") }
        try pinned.verify(source)
    }
}
