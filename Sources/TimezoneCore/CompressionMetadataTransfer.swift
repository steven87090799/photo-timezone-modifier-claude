import Foundation

/// Transfers metadata to a disposable compressed output, never to a source photo.
/// Re-encoding changes dimensions/orientation; dates, offsets and GPS are copied as values.
public enum CompressionMetadataTransfer {
    public static func preserve(source: URL, output: URL, width: Int, height: Int,
                                profile: Data?, originalProfile: Bool,
                                exiftoolURL: URL? = nil, cancellation: CancellationToken? = nil) throws -> String {
        let tool = ExifTool(url: try exiftoolURL ?? EngineResources.exiftoolURL())
        // libjxl emits a raw codestream. Use the standard container so EXIF/XMP
        // can be added without globally ignoring ExifTool's minor errors.
        let isJXL = output.pathExtension.lowercased() == "jxl"
        if isJXL { try wrapJXLCodestream(output) }
        let pinned = try FileIdentity.read(source)
        let before = try tool.snapshot(source, cancellation: cancellation, strictOffsets: false)
        let originalICC = try tool.execute(["-b", "-ICC_Profile", source.path], timeout: 120, cancellation: cancellation).stdout
        let expectedICC = originalProfile && !originalICC.isEmpty ? originalICC : profile
        let profileURL = output.deletingLastPathComponent().appendingPathComponent("output-profile.icc")
        defer { try? FileManager.default.removeItem(at: profileURL) }
        var arguments = ["-overwrite_original", "-TagsFromFile", source.path,
            "-EXIF:all", "-XMP:all", "-IPTC:all", "--ThumbnailImage", "--PreviewImage"]
        if let expectedICC, !expectedICC.isEmpty, !isJXL {
            try expectedICC.write(to: profileURL, options: .atomic)
            arguments.append("-ICC_Profile<=\(profileURL.path)")
        }
        if before.embeddedTags.keys.contains(where: { $0.hasSuffix(":Orientation") }) {
            arguments += ["-EXIF:Orientation#=1"]
            if before.embeddedTags.keys.contains(where: { $0.hasPrefix("XMP-tiff:") && $0.hasSuffix(":Orientation") }) {
                arguments += ["-XMP-tiff:Orientation#=1"]
            }
        }
        if before.embeddedTags.keys.contains(where: { $0.hasSuffix(":ExifImageWidth") }) {
            arguments += ["-ExifIFD:ExifImageWidth=\(width)", "-ExifIFD:ExifImageHeight=\(height)"]
        }
        if before.embeddedTags.keys.contains(where: { $0.hasPrefix("XMP-exif:") && $0.hasSuffix(":ExifImageWidth") }) {
            arguments += ["-XMP-exif:ExifImageWidth=\(width)", "-XMP-exif:ExifImageHeight=\(height)"]
        }
        if before.embeddedTags.keys.contains(where: { $0.hasPrefix("XMP-tiff:") && $0.hasSuffix(":ImageWidth") }) {
            arguments += ["-XMP-tiff:ImageWidth=\(width)", "-XMP-tiff:ImageHeight=\(height)"]
        }
        let toolkit = before.embeddedTags["XMP-x:XMPToolkit"].flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed])) as? String
        }
        arguments.append("-XMP-x:XMPToolkit=\(toolkit ?? "")")
        let write = try tool.execute(arguments + [output.path], timeout: 120, cancellation: cancellation)
        guard write.status == 0 else { throw PhotoError("壓縮已完成，但中繼資料無法安全寫入；未接受此輸出。\(write.text)") }
        let after = try tool.snapshot(output, cancellation: cancellation, strictOffsets: false)
        try pinned.verify(source)
        let ignored: Set<String> = ["Orientation", "ExifImageWidth", "ExifImageHeight", "ImageWidth", "ImageHeight",
            "XMPToolkit", "ThumbnailImage", "PreviewImage", "ThumbnailOffset", "ThumbnailLength",
            "Compression", "PhotometricInterpretation", "BitsPerSample", "SamplesPerPixel", "RowsPerStrip",
            "StripOffsets", "StripByteCounts", "TileOffsets", "TileByteCounts", "PlanarConfiguration", "YCbCrSubSampling"]
        var missing: [String] = []
        for (key, value) in before.embeddedTags {
            let group = key.split(separator: ":").first.map(String.init) ?? ""
            let tag = key.split(separator: ":").last.map(String.init) ?? ""
            guard ["IFD0", "ExifIFD", "InteropIFD", "GPS", "IPTC"].contains(group) || group.hasPrefix("XMP") else { continue }
            guard !ignored.contains(tag) else { continue }
            let canonical = MetadataVerifier.canonicalCopyKey(key)
            let matches = after.embeddedTags.filter { MetadataVerifier.canonicalCopyKey($0.key) == canonical }
            if matches.isEmpty || !matches.values.allSatisfy({ $0 == value }) { missing.append(canonical) }
        }
        let readICC = try tool.execute(["-b", "-ICC_Profile", output.path], timeout: 120, cancellation: cancellation).stdout
        let iccMatches = expectedICC.map { !$0.isEmpty && $0 == readICC } ?? readICC.isEmpty
        if originalProfile && expectedICC?.isEmpty == false && !iccMatches {
            throw PhotoError("此輸出未能保留來源 RGB 色彩描述檔；避免顏色錯誤，未接受此輸出。")
        }
        let hasWarnings = !before.warnings.isEmpty || !after.warnings.isEmpty || !write.stderr.isEmpty
        let metadata = missing.isEmpty ? (hasWarnings ? "已核對可讀欄位；中繼資料有讀寫警告，完整保留未確認" : "已驗證一般 EXIF／XMP／IPTC（保留既有時區及 GPS）") :
            "部分中繼資料未保留：\(Set(missing).sorted().prefix(5).joined(separator: "、"))\(missing.count > 5 ? "等 \(missing.count) 欄" : "")"
        let color: String
        if originalProfile && !originalICC.isEmpty && iccMatches { color = "原 ICC 已完整保留" }
        else if originalProfile && iccMatches { color = "已嵌入來源 RGB 色彩描述檔" }
        else { color = iccMatches ? "像素與 ICC 已轉為 sRGB" : "像素使用 sRGB；此容器未寫入 ICC" }
        return metadata + "；" + color
    }

    private static func wrapJXLCodestream(_ url: URL) throws {
        let stream = try Data(contentsOf: url, options: .mappedIfSafe)
        guard stream.starts(with: [0xff, 0x0a]) else { return }
        guard stream.count > 12, stream.count <= Int(UInt32.max) - 8 else { throw PhotoError("JPEG XL 碼流尺寸無效。") }
        var container = Data([0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 0x0d, 0x0a, 0x87, 0x0a,
            0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x6a, 0x78, 0x6c, 0x20, 0, 0, 0, 0, 0x6a, 0x78, 0x6c, 0x20])
        var length = UInt32(stream.count + 8).bigEndian
        withUnsafeBytes(of: &length) { container.append(contentsOf: $0) }
        container.append(Data("jxlc".utf8)); container.append(stream)
        try container.write(to: url, options: .atomic)
    }
}
