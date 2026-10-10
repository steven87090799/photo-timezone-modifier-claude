import Foundation

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
        let before = try tool.snapshot(source, cancellation: cancellation, strictOffsets: false, forCompression: true)
        let originalICC = try tool.execute(["-b", "-ICC_Profile", source.path], timeout: 120, cancellation: cancellation).stdout
        let expectedICC = originalProfile && !originalICC.isEmpty ? originalICC : profile
        let profileURL = output.deletingLastPathComponent().appendingPathComponent("output-profile.icc")
        defer { try? FileManager.default.removeItem(at: profileURL) }
        var arguments = ["-overwrite_original", "-TagsFromFile", source.path,
            "-EXIF:all", "-MakerNotes", "-XMP", "-IPTC", "--ThumbnailImage", "--PreviewImage"]
        if preservePhotoEXIF {
            arguments.removeAll { ["--ThumbnailImage", "--PreviewImage"].contains($0) }
            arguments += ["-ThumbnailImage", "-PreviewImage"]
        }
        if let expectedICC, !expectedICC.isEmpty, !isJXL {
            try expectedICC.write(to: profileURL, options: .atomic)
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
        let toolkit = before.embeddedTags["XMP-x:XMPToolkit"].flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed])) as? String
        }
        arguments.append("-XMP-x:XMPToolkit=\(toolkit ?? "")")
        let write = try tool.execute(arguments + [output.path], timeout: 120, cancellation: cancellation)
        guard write.status == 0 else { throw PhotoError("壓縮已完成，但中繼資料無法安全寫入；未接受此輸出。\(write.text)") }
        let after = try tool.snapshot(output, cancellation: cancellation, strictOffsets: false, forCompression: true)
        try pinned.verify(source)
        var ignored: Set<String> = ["Orientation", "ExifImageWidth", "ExifImageHeight", "ImageWidth", "ImageHeight",
            "XMPToolkit", "ThumbnailImage", "PreviewImage", "ThumbnailOffset", "ThumbnailLength",
            "Compression", "PhotometricInterpretation", "BitsPerSample", "SamplesPerPixel", "RowsPerStrip",
            "StripOffsets", "StripByteCounts", "TileOffsets", "TileByteCounts", "PlanarConfiguration", "YCbCrSubSampling", "YCbCrPositioning", "FillOrder", "SampleFormat"]
        if preservePhotoEXIF { ignored.subtract(["Orientation", "ExifImageWidth", "ExifImageHeight"]) }
        var missing: [String] = []
        func relevant(_ key: String) -> Bool {
            let group = key.split(separator: ":").first.map(String.init) ?? ""
            let tag = key.split(separator: ":").last.map(String.init) ?? ""
            return (["IFD0", "ExifIFD", "InteropIFD", "GPS", "IPTC"].contains(group) || group.hasPrefix("XMP")) && !ignored.contains(tag)
        }
        let originalGroups = Dictionary(grouping: before.embeddedTags.filter { relevant($0.key) }, by: { comparisonKey($0.key) })
        let outputGroups = Dictionary(grouping: after.embeddedTags.filter { relevant($0.key) }, by: { comparisonKey($0.key) })
        for (key, entries) in originalGroups {
            if !metadataValuesMatch(key: key, entries.map(\.value), outputGroups[key]?.map(\.value) ?? []) {
                missing.append(key)
            }
        }
        if preservePhotoEXIF {
            let makerBefore = try tool.execute(["-b", "-MakerNotes", source.path], timeout: 120, cancellation: cancellation).stdout
            let makerAfter = try tool.execute(["-b", "-MakerNotes", output.path], timeout: 120, cancellation: cancellation).stdout
            guard makerBefore == makerAfter else { throw PhotoError("相機 MakerNotes 無法完整保留，未接受此輸出。") }
            for tag in ["ThumbnailImage", "PreviewImage"] {
                let original = try tool.execute(["-b", "-\(tag)", source.path], timeout: 120, cancellation: cancellation).stdout
                if !original.isEmpty {
                    let copied = try tool.execute(["-b", "-\(tag)", output.path], timeout: 120, cancellation: cancellation).stdout
                    guard original == copied else { throw PhotoError("EXIF \(tag) 無法完整保留，未接受此輸出。") }
                }
            }
            let changedEXIF = missing.filter { key in
                ["EXIF", "IFD0", "ExifIFD", "InteropIFD", "GPS"].contains(String(key.split(separator: ":").first ?? ""))
            }
            guard changedEXIF.isEmpty else {
                throw PhotoError("EXIF 保留驗證失敗，未接受此輸出：\(changedEXIF.sorted().joined(separator: "、"))")
            }
            guard before.warnings.isEmpty && after.warnings.isEmpty else {
                throw PhotoError("EXIF 無法完整可靠核對，未接受此輸出。\(before.warnings) \(after.warnings)")
            }
        }
        let readICC = try tool.execute(["-b", "-ICC_Profile", output.path], timeout: 120, cancellation: cancellation).stdout
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
        let hasWarnings = !before.warnings.isEmpty || !after.warnings.isEmpty || !write.stderr.isEmpty
        let missingIPTC = Set(missing.filter { $0.hasPrefix("IPTC:") }).sorted()
        let isIPTCOnlyLoss = !missingIPTC.isEmpty && missingIPTC.count == missing.count &&
            ["webp", "avif", "heic", "jxl"].contains(output.pathExtension.lowercased())
        let metadata: String
        if missing.isEmpty {
            metadata = hasWarnings ? "已核對可讀欄位；中繼資料有讀寫警告，完整保留未確認" :
                "已驗證一般 EXIF／XMP／IPTC（保留既有時區及 GPS）"
        } else if isIPTCOnlyLoss {
            metadata = "此格式輸出未保留來源 IPTC-IIM 欄位：\(missingIPTC.map { String($0.dropFirst(5)) }.joined(separator: "、"))"
        } else {
            metadata = "部分中繼資料未保留：\(Set(missing).sorted().prefix(5).joined(separator: "、"))\(missing.count > 5 ? "等 \(missing.count) 欄" : "")"
        }
        let color: String
        if originalProfile && !originalICC.isEmpty && iccMatches {
            color = isJXL ? "原 ICC 色彩特性已驗證" : "原 ICC 已完整保留"
        }
        else if originalProfile && iccMatches { color = "已嵌入來源 RGB 色彩描述檔" }
        else { color = iccMatches ? "像素與 ICC 已轉為 sRGB" : "像素使用 sRGB；此容器未寫入 ICC" }
        return metadata + "；" + color
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
        // ExifTool decodes the EXIF rational FNumber as a decimal. Rewriting a
        // rational can change its decimal spelling by a few floating-point
        // units (for example 5.599999905 -> 5.6) without changing the aperture.
        // Keep every other tag, especially XMP values, byte-for-byte strict.
        guard key == "ExifIFD:FNumber", original.count == output.count else { return false }
        return zip(original, output).allSatisfy { lhs, rhs in
            guard let left = jsonNumber(lhs), let right = jsonNumber(rhs) else { return false }
            let tolerance = max(0.000001, max(abs(left), abs(right)) * 0.000000001)
            return abs(left - right) <= tolerance
        }
    }

    private static func jsonNumber(_ value: String) -> Double? {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let number = decoded as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

}
