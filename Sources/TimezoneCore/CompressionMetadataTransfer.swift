import Foundation
import CoreFoundation

/// Transfers metadata to a disposable compressed output, never to a source photo.
/// Dates, offsets and GPS are copied as values; photo EXIF preservation also
/// retains orientation and declared dimensions while encoded layout may change.
public enum CompressionMetadataTransfer {
    public static func exifOrientation(_ source: URL, exiftoolURL: URL) throws -> Int {
        let value = try ExifTool(url: exiftoolURL).execute(["-s3", "-n", "-a", "-EXIF:Orientation", source.path])
        guard value.status == 0 else { throw PhotoError("無法可靠讀取 EXIF 方向。") }
        let text = String(decoding: value.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 1 }
        let values = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        guard values.count == 1, let value = values.first, let orientation = Int(value), (1...8).contains(orientation) else { throw PhotoError("EXIF 方向無效或互相衝突，已停止輸出。") }
        return orientation
    }
    public static func preserve(source: URL, output: URL, width: Int, height: Int,
                                profile: Data?, originalProfile: Bool,
                                exiftoolURL: URL? = nil, cancellation: CancellationToken? = nil,
                                iccVerifier: ((URL, Data) -> Bool)? = nil,
                                preservePhotoEXIF: Bool = false) throws -> String {
        let tool = ExifTool(url: try exiftoolURL ?? EngineResources.exiftoolURL(), persistent: true)
        let isJXL = output.pathExtension.lowercased() == "jxl"
        let pinned = try FileIdentity.read(source)
        try CompressionContainerInventory.validate(source)
        let before = try tool.snapshot(source, cancellation: cancellation, strictOffsets: false, forCompression: true)
        func binaryTag(_ tag: String, in file: URL) throws -> Data {
            let read = try tool.execute(["-m", "-a", "-b", "-\(tag)", file.path], timeout: 120, cancellation: cancellation)
            guard read.status == 0 else { throw PhotoError("無法可靠讀取 \(tag)，未接受此輸出。\(read.text)") }
            return read.stdout
        }
        // JPEG/HEIF can carry the original TIFF-form EXIF block. Copy it as a
        // block instead of round-tripping every rational through ExifTool's
        // ValueConv (APEX aperture/shutter conversions are not lossless).
        // This also preserves unknown tags, duplicates and camera-private data.
        let canCarryOriginalEXIF = before.metadata.fileType == "JPEG" ||
            (["HEIC", "HEIF"].contains(before.metadata.fileType ?? "") && output.pathExtension.lowercased() == "heic")
        let originalEXIF = preservePhotoEXIF && canCarryOriginalEXIF ? try binaryTag("EXIF", in: source) : Data()
        let copiesEXIFBlock = !originalEXIF.isEmpty
        // These blocks can contain private data that has no writable, named
        // ExifTool tag. A list of matching decoded fields cannot prove that
        // this data survived. MakerNotes copying also excludes PreviewImage
        // unless it is explicitly requested (ExifTool -tagsFromFile docs).
        let protectedBlocks = try Dictionary(uniqueKeysWithValues:
            ["MakerNotes", "ThumbnailImage", "PreviewImage", "IPTC", "Comment"].map {
                ($0, try binaryTag($0, in: source))
            })
        let originalXMP = try binaryTag("XMP", in: source)
        let originalICC = try binaryTag("ICC_Profile", in: source)
        // ImageIO may emit an empty IPTC resource plus its standard empty-data
        // digest. There are no IPTC values to copy; requesting that empty block
        // makes ExifTool warn when writing containers without IPTC support.
        let emptyIPTCDigest = protectedBlocks["IPTC"]?.isEmpty == true &&
            before.embeddedTags["Photoshop:IPTCDigest"] == "\"d41d8cd98f00b204e9800998ecf8427e\""
        guard originalICC.isEmpty || originalProfile else {
            throw PhotoError("此轉檔會取代來源 ICC 色彩描述檔，未接受此輸出。請選擇可保留原始色彩描述檔的格式。")
        }
        // A PNG sRGB chunk already declares the color space and rendering
        // intent. PNG recommends avoiding simultaneous sRGB and iCCP chunks.
        // Keep the original declaration rather than replacing this source
        // metadata with a generated profile.
        let preservesPNGsRGB = output.pathExtension.lowercased() == "png" && originalICC.isEmpty &&
            before.embeddedTags.keys.contains { MetadataVerifier.canonicalCopyKey($0) == "PNG:SRGBRendering" }
        let expectedICC = preservesPNGsRGB ? nil : originalProfile && !originalICC.isEmpty ? originalICC : profile
        let profileURL = output.deletingLastPathComponent().appendingPathComponent("output-profile.icc")
        defer { try? FileManager.default.removeItem(at: profileURL) }
        var arguments = ["-overwrite_original", "-TagsFromFile", source.path,
            "-EXIF:all", "-MakerNotes", "-XMP", "-IPTC", "-ThumbnailImage", "-PreviewImage", "-Comment"]
        if protectedBlocks["IPTC"]?.isEmpty == true { arguments.removeAll { $0 == "-IPTC" } }
        if output.pathExtension.lowercased() == "jpg",
           before.embeddedTags.keys.contains(where: { $0.hasPrefix("JFIF:") }) {
            arguments.append("-JFIF:all")
        }
        if before.embeddedTags.keys.contains(where: {
            $0.hasPrefix("Photoshop:") && (!emptyIPTCDigest || $0 != "Photoshop:IPTCDigest")
        }) || (emptyIPTCDigest && output.pathExtension.lowercased() == "jpg") {
            arguments.append("-Photoshop:all")
        }
        if output.pathExtension.lowercased() == "png",
           before.embeddedTags.keys.contains(where: { $0.hasPrefix("PNG:") }) {
            arguments.append("-PNG:all")
            // Color declarations are marked Unsafe by ExifTool and are not
            // included in wildcard copies. The PNG path keeps source RGB
            // samples, so copy its original declarations explicitly.
            if preservesPNGsRGB { arguments.append("-PNG:SRGBRendering") }
        }
        if copiesEXIFBlock {
            arguments.removeAll { ["-EXIF:all", "-MakerNotes", "-ThumbnailImage", "-PreviewImage"].contains($0) }
            arguments.append("-EXIF")
        }
        if output.pathExtension.lowercased() == "jpg", !copiesEXIFBlock {
            // A PNG/TIFF EXIF directory need not contain JPEG's required fields.
            // Supply missing declarations without altering any existing value.
            let defaults = [("ExifIFD:ExifVersion", "0232"),
                ("ExifIFD:ComponentsConfiguration", "1 2 3 0"),
                ("ExifIFD:ColorSpace", "65535"), ("IFD0:YCbCrPositioning", "1"),
                ("ExifIFD:ExifImageWidth", String(width)), ("ExifIFD:ExifImageHeight", String(height))]
            for (tag, value) in defaults where !before.embeddedTags.keys.contains(where: {
                MetadataVerifier.canonicalCopyKey($0) == tag
            }) { arguments.append("-\(tag)#=\(value)") }
        }
        // Preserve the digest paired with the raw IPTC block in JPEG. Some
        // encoders leave a Photoshop digest behind; replacing only IPTC would
        // then introduce a spurious "XMP may be out of sync" warning.
        if output.pathExtension.lowercased() == "jpg",
           before.embeddedTags.keys.contains(where: { $0.hasPrefix("Photoshop:") && $0.hasSuffix(":IPTCDigest") }) {
            arguments.append("-Photoshop:IPTCDigest")
        }
        if let expectedICC, !expectedICC.isEmpty, !isJXL {
            try expectedICC.write(to: profileURL, options: .atomic)
            if output.pathExtension.lowercased() == "heic" {
                try HEIFICCProfile.prepareForWrite(output)
            }
            arguments.append("-ICC_Profile<=\(profileURL.path)")
        }
        if !preservePhotoEXIF && before.embeddedTags.keys.contains(where: { $0.hasSuffix(":Orientation") }) {
            arguments += ["-EXIF:Orientation#=1"]
            if before.embeddedTags.keys.contains(where: { $0.hasPrefix("XMP-tiff:") && $0.hasSuffix(":Orientation") }) {
                arguments += ["-XMP-tiff:Orientation#=1"]
            }
        }
        if !preservePhotoEXIF && before.embeddedTags.keys.contains(where: { $0.hasSuffix(":ExifImageWidth") }) {
            arguments += ["-ExifIFD:ExifImageWidth=\(width)", "-ExifIFD:ExifImageHeight=\(height)"]
        }
        if !preservePhotoEXIF && before.embeddedTags.keys.contains(where: { $0.hasPrefix("XMP-exif:") && $0.hasSuffix(":ExifImageWidth") }) {
            arguments += ["-XMP-exif:ExifImageWidth=\(width)", "-XMP-exif:ExifImageHeight=\(height)"]
        }
        if !preservePhotoEXIF && before.embeddedTags.keys.contains(where: { $0.hasPrefix("XMP-tiff:") && $0.hasSuffix(":ImageWidth") }) {
            arguments += ["-XMP-tiff:ImageWidth=\(width)", "-XMP-tiff:ImageHeight=\(height)"]
        }
        let changesXMP = arguments.contains { $0.hasPrefix("-XMP-") }
        if changesXMP {
            let toolkit = before.embeddedTags.first { comparisonKey($0.key) == "XMP-x:XMPToolkit" }.flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.value.utf8), options: [.fragmentsAllowed])) as? String
            }
            arguments.append("-XMP-x:XMPToolkit=\(toolkit ?? "")")
        }
        let write = try tool.execute(arguments + [output.path], timeout: 120, cancellation: cancellation)
        guard write.status == 0 else { throw PhotoError("壓縮已完成，但中繼資料無法安全寫入；未接受此輸出。\(write.text)") }
        if output.pathExtension.lowercased() == "png" {
            try CompressionContainerInventory.preservePNGColorDeclaration(source: source, output: output)
        }
        let after = try tool.snapshot(output, cancellation: cancellation, strictOffsets: false, forCompression: true)
        try pinned.verify(source)
        if copiesEXIFBlock {
            guard try binaryTag("EXIF", in: output) == originalEXIF else {
                throw PhotoError("原始 EXIF 區塊未完整保留，未接受此輸出。")
            }
        }
        let readICC = try binaryTag("ICC_Profile", in: output)
        // PNG's iCCP keyword labels a container chunk, rather than adding
        // fields to the ICC payload. A different container can carry the same
        // complete profile without carrying this PNG-specific label.
        let replacesPNGProfileLabel = output.pathExtension.lowercased() != "png" &&
            !originalICC.isEmpty && originalICC == readICC
        // An sRGB PNG may use a one-byte intent instead of an ICC profile.
        // Cross-container replacement is safe only when both the exact
        // decoded source profile and its rendering intent survive. A merely
        // similar profile, or a different intent, is insufficient evidence.
        let sourceSRGBIntent = before.embeddedTags.first {
            MetadataVerifier.canonicalCopyKey($0.key) == "PNG:SRGBRendering"
        }.flatMap { jsonNumber($0.value) }
        let targetICCIntent = after.embeddedTags.first {
            MetadataVerifier.canonicalCopyKey($0.key) == "ICC-header:RenderingIntent"
        }.flatMap { jsonNumber($0.value) }
        let replacesPNGsRGBDeclaration = output.pathExtension.lowercased() != "png" &&
            originalProfile && originalICC.isEmpty && profile?.isEmpty == false &&
            ((profile == readICC && sourceSRGBIntent != nil && sourceSRGBIntent == targetICCIntent) ||
             (isJXL && profile.map { iccVerifier?(output, $0) == true &&
                $0.count >= 68 && sourceSRGBIntent == Double($0[64]) * 16777216 + Double($0[65]) * 65536 +
                    Double($0[66]) * 256 + Double($0[67]) } == true))
        var missing: [String] = []
        func numeric(_ tags: [String: String], _ key: String) -> Double? {
            tags.first { MetadataVerifier.canonicalCopyKey($0.key) == key }.flatMap { jsonNumber($0.value) }
        }
        let jfifUnit = numeric(before.embeddedTags, "JFIF:ResolutionUnit")
        let jfifX = numeric(before.embeddedTags, "JFIF:XResolution")
        let jfifY = numeric(before.embeddedTags, "JFIF:YResolution")
        // Unit 0 with equal densities is the default square-pixel declaration.
        // Real print density must survive as JFIF, or as identical EXIF density.
        let equivalentEXIFDensity = jfifUnit != nil && jfifX != nil && jfifY != nil &&
            numeric(after.embeddedTags, "IFD0:ResolutionUnit") == jfifUnit.map { $0 + 1 } &&
            numeric(after.embeddedTags, "IFD0:XResolution") == jfifX &&
            numeric(after.embeddedTags, "IFD0:YResolution") == jfifY
        let replacesJFIFDensity = output.pathExtension.lowercased() != "jpg" &&
            ((jfifUnit == 0 && jfifX != nil && jfifX == jfifY) || equivalentEXIFDensity)
        func relevant(_ key: String) -> Bool {
            let canonical = MetadataVerifier.canonicalCopyKey(key)
            if ["JFIF:ResolutionUnit", "JFIF:XResolution", "JFIF:YResolution"].contains(canonical) {
                return !replacesJFIFDensity
            }
            if emptyIPTCDigest && canonical == "Photoshop:IPTCDigest" { return false }
            if canonical == "PNG:ProfileName" && replacesPNGProfileLabel { return false }
            if canonical == "PNG:SRGBRendering" && replacesPNGsRGBDeclaration { return false }
            return isPreservedMetadataKey(key, preservePhotoEXIF: preservePhotoEXIF)
        }
        let originalGroups = Dictionary(grouping: before.embeddedTags.filter { relevant($0.key) }, by: { comparisonKey($0.key) })
        let outputGroups = Dictionary(grouping: after.embeddedTags.filter { relevant($0.key) }, by: { comparisonKey($0.key) })
        for (key, entries) in originalGroups {
            if !metadataValuesMatch(key: key, entries.map(\.value), outputGroups[key]?.map(\.value) ?? []) {
                missing.append(key)
            }
            // A binary summary contains only a length, not its payload. Never
            // accept two equal-length opaque values as preservation evidence.
            // EXIF and MakerNotes blocks already provide stronger evidence.
            if entries.contains(where: { $0.value.contains("(Binary data ") }),
               !["ThumbnailImage", "PreviewImage"].contains(String(key.split(separator: ":").last ?? "")) {
                let original = try binaryTag(key, in: source)
                guard !original.isEmpty, try binaryTag(key, in: output) == original else {
                    throw PhotoError("不透明中繼資料 \(key) 無法逐位元組確認保留，未接受此輸出。")
                }
            }
        }
        for (tag, original) in protectedBlocks where !original.isEmpty {
            guard try binaryTag(tag, in: output) == original else {
                let name = tag == "IPTC" ? "IPTC-IIM" : tag
                throw PhotoError("\(output.pathExtension.uppercased()) 無法完整保留來源 \(name) 區塊，未接受此輸出。請選擇可保留此中繼資料的格式。")
            }
        }
        if !originalXMP.isEmpty && !changesXMP {
            guard try xmpPacketsMatch(originalXMP, binaryTag("XMP", in: output)) else {
                throw PhotoError("原始 XMP 區塊無法完整保留，未接受此輸出。")
            }
        }
        guard missing.isEmpty else {
            throw PhotoError("\(output.pathExtension.uppercased()) 中繼資料保留驗證失敗，未接受此輸出：\(Set(missing).sorted().joined(separator: "、"))")
        }
        // Unchanged warnings are acceptable only when a complete EXIF block
        // has been checked byte-for-byte. Any new read/write warning rejects.
        guard ((before.warnings.isEmpty && after.warnings.isEmpty) ||
                (copiesEXIFBlock && before.warnings == after.warnings)), write.stderr.isEmpty else {
            throw PhotoError("中繼資料無法完整可靠核對，未接受此輸出。\(before.warnings) \(after.warnings) \(write.stderr)")
        }
        let iccMatches: Bool
        if isJXL, originalProfile, let expectedICC, !expectedICC.isEmpty {
            guard let iccVerifier else {
                throw PhotoError("JPEG XL 色彩描述檔尚未完成驗證；未接受此輸出。")
            }
            iccMatches = iccVerifier(output, expectedICC)
        } else {
            iccMatches = expectedICC.map { !$0.isEmpty && $0 == readICC } ?? readICC.isEmpty
        }
        if originalProfile && expectedICC?.isEmpty == false && !iccMatches {
            throw PhotoError("此輸出未能保留來源 RGB 色彩描述檔；避免顏色錯誤，未接受此輸出。")
        }
        let structureWarnings = try MetadataStructureVerifier.verify(source: source, candidate: output, tool: tool, cancellation: cancellation)
        let metadata = "中繼資料保留核對通過（既有時區及 GPS 不變）"
        let color: String
        if preservesPNGsRGB { color = "原 PNG sRGB 宣告與呈現意圖已保留" }
        else if originalProfile && !originalICC.isEmpty && iccMatches {
            color = "原 ICC 已完整保留"
        }
        else if originalProfile && iccMatches { color = "已嵌入來源 RGB 色彩描述檔" }
        else { color = iccMatches ? "像素與 ICC 已轉為 sRGB" : "像素使用 sRGB；此容器未寫入 ICC" }
        let structure = structureWarnings.isEmpty ? "" :
            "；來源已有 \(structureWarnings.count) 項 EXIF／容器結構診斷，輸出未新增，請保留原件"
        return metadata + (copiesEXIFBlock ? "；原始 EXIF 區塊逐位元組一致" : "") + "；" + color + structure
    }

    /// The xpacket trailer declares whether in-place packet edits are allowed.
    /// ExifTool changes only this packaging flag between JPEG and PNG. All
    /// other packet bytes, including unknown properties and padding, must match.
    static func xmpPacketsMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        func normalized(_ packet: Data) -> Data {
            for quote in ["'", "\""] {
                let readOnly = Data("<?xpacket end=\(quote)r\(quote)?>".utf8)
                if packet.suffix(readOnly.count) == readOnly {
                    return packet.dropLast(readOnly.count) + Data("<?xpacket end=\(quote)w\(quote)?>".utf8)
                }
            }
            return packet
        }
        return normalized(lhs) == normalized(rhs)
    }

    /// Only codec/container layout may change during re-encoding. Unknown
    /// namespaces and private metadata default to preservation checks. In
    /// particular a private XMP tag named "Orientation" or "Compression" is
    /// not a layout field just because its local name matches an EXIF tag.
    static func isPreservedMetadataKey(_ key: String, preservePhotoEXIF: Bool) -> Bool {
        let key = MetadataVerifier.canonicalCopyKey(key)
        let parts = key.split(separator: ":")
        guard parts.count == 2 else { return true }
        let group = String(parts[0]), tag = String(parts[1])
        if group == "ICC_Profile" || group.hasPrefix("ICC-") { return false } // raw block verified separately
        if group.hasPrefix("XMP") {
            let normalized: Set<String> = ["XMP-tiff:Orientation", "XMP-exif:ExifImageWidth",
                "XMP-exif:ExifImageHeight", "XMP-tiff:ImageWidth", "XMP-tiff:ImageHeight"]
            return preservePhotoEXIF || !normalized.contains(key)
        }
        let exifGroups: Set<String> = ["IFD0", "IFD1", "ExifIFD", "InteropIFD", "SubIFD"]
        if exifGroups.contains(group) {
            var layout: Set<String> = ["ImageWidth", "ImageHeight", "ThumbnailImage", "PreviewImage",
                "ThumbnailOffset", "ThumbnailLength", "Compression", "PhotometricInterpretation",
                "BitsPerSample", "SamplesPerPixel", "RowsPerStrip", "StripOffsets", "StripByteCounts",
                "TileOffsets", "TileByteCounts", "PlanarConfiguration", "YCbCrSubSampling", "YCbCrPositioning",
                "FillOrder", "SampleFormat", "ExtraSamples"]
            if !preservePhotoEXIF { layout.formUnion(["Orientation", "ExifImageWidth", "ExifImageHeight"]) }
            return !layout.contains(tag)
        }
        let layout: [String: Set<String>] = [
            "JFIF": ["JFIFVersion", "ResolutionUnit", "XResolution", "YResolution"],
            "Adobe": ["DCTEncodeVersion", "APP14Flags0", "APP14Flags1", "ColorTransform"],
            "PNG": ["ImageWidth", "ImageHeight", "BitDepth", "ColorType", "Compression", "Filter", "Interlace"],
            "GIF": ["GIFVersion", "ImageWidth", "ImageHeight", "HasColorMap", "ColorResolutionDepth",
                "BitsPerPixel", "BackgroundColor", "TransparentColor", "GraphicControlFlags", "Delay",
                "AnimationIterations"],
            "RIFF": ["VP8Version", "ImageWidth", "ImageHeight", "HorizontalScale", "VerticalScale",
                "VP8LVersion", "AlphaIsUsed", "AnimationFrameFlags", "CanvasWidth", "CanvasHeight"],
            "JXL": ["ImageWidth", "ImageHeight", "BitsPerSample", "AlphaBits", "ColorEncoding",
                "Orientation", "HavePreview", "HaveAnimation", "UsesOriginalProfile"],
            "Meta": ["PrimaryItemReference"],
            "QuickTime": ["MajorBrand", "MinorVersion", "CompatibleBrands", "HandlerType", "HandlerDescription",
                "ColorProfiles", "ColorPrimaries", "TransferCharacteristics", "MatrixCoefficients", "VideoFullRangeFlag",
                "MaxContentLightLevel", "MaxPicAverageLightLevel", "ImageSpatialExtent", "CleanAperture", "Rotation", "Mirroring",
                "ImagePixelDepth", "HEVCConfigurationVersion", "GeneralProfileSpace", "GeneralTierFlag", "GeneralProfileIDC",
                "GenProfileCompatibilityFlags", "ConstraintIndicatorFlags", "GeneralLevelIDC", "MinSpatialSegmentationIDC",
                "ParallelismType", "ChromaFormat", "BitDepthLuma", "BitDepthChroma", "AverageFrameRate", "ConstantFrameRate",
                "NumTemporalLayers", "TemporalIDNested", "MediaDataSize", "MediaDataOffset", "MediaData",
                "AV1ConfigurationVersion", "ChromaSubsamplingX", "ChromaSubsamplingY", "ChromaSamplePosition",
                "SequenceProfile", "SequenceLevelIndex0", "SequenceTier0", "HighBitDepth", "TwelveBit", "Monochrome"]
        ]
        if group == "QuickTime", tag.hasPrefix("QuickTime_HEVCConfig_") { return false }
        return layout[group]?.contains(tag) != true
    }

    // Only these EXIF tags may legally move between the main and Exif IFD.
    // XMP namespaces and duplicate instances remain distinct; no general
    // same-name matching that could hide a missing proprietary field.
    static func comparisonKey(_ key: String) -> String {
        let canonical = MetadataVerifier.canonicalCopyKey(key)
        let parts = canonical.split(separator: ":")
        let relocatable: Set<String> = ["ImageDescription", "Make", "Model", "XResolution", "YResolution", "ResolutionUnit", "ModifyDate", "Software", "Artist", "Copyright", "Orientation"]
        if parts.count == 2, ["IFD0", "ExifIFD"].contains(String(parts[0])), relocatable.contains(String(parts[1])) {
            return "EXIF:\(parts[1])"
        }
        return canonical
    }

    static func metadataValuesMatch(key: String, _ original: [String], _ output: [String]) -> Bool {
        let original = original.sorted(), output = output.sorted()
        if original == output { return true }
        // Fallback for sources without an extractable EXIF block (e.g. TIFF).
        // Only photographic rational measurements permit bounded rounding.
        // Dates, offsets, GPS, XMP, integers and missing/duplicate values remain
        // strict. APEX ValueConv needs relative precision for long exposures.
        let rationalMeasurements: Set<String> = [
            "ExifIFD:FNumber", "ExifIFD:ApertureValue", "ExifIFD:MaxApertureValue",
            "ExifIFD:ShutterSpeedValue", "ExifIFD:ExposureTime", "ExifIFD:ExposureCompensation",
            "ExifIFD:BrightnessValue", "ExifIFD:FocalLength", "ExifIFD:SubjectDistance",
            "ExifIFD:ExposureIndex", "ExifIFD:DigitalZoomRatio",
            "ExifIFD:FocalPlaneXResolution", "ExifIFD:FocalPlaneYResolution",
            "IFD0:XResolution", "IFD0:YResolution"
        ]
        guard rationalMeasurements.contains(key), original.count == output.count else { return false }
        let originalNumbers = original.compactMap(jsonNumber).sorted()
        let outputNumbers = output.compactMap(jsonNumber).sorted()
        guard originalNumbers.count == original.count, outputNumbers.count == output.count else { return false }
        return zip(originalNumbers, outputNumbers).allSatisfy { left, right in
            let tolerance = key == "ExifIFD:FNumber" ?
                max(0.000001, max(abs(left), abs(right)) * 0.000000001) :
                max(0.000000001, max(abs(left), abs(right)) * 0.000001)
            return abs(left - right) <= tolerance
        }
    }

    private static func jsonNumber(_ value: String) -> Double? {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let number = decoded as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

}
