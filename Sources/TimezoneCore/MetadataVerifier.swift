import Foundation
import CoreFoundation

/// Metadata-only verification chosen by the user. No photo, preview, thumbnail,
/// or MakerNotes digest is calculated. Unknown binary payloads are NOT certified.
enum MetadataVerifier {
    /// ExifTool's -a -G1:4 assigns Copy1/Copy2 to duplicate tags. Those
    /// instances remain distinct readback values and must all match a write.
    static func canonicalCopyKey(_ key: String) -> String {
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[1].hasPrefix("Copy"),
              Int(parts[1].dropFirst(4)) != nil else { return key }
        return "\(parts[0]):\(parts[2])"
    }

    static func verifyIntegrated(before: ExifTool.Snapshot, after: ExifTool.Snapshot,
                                 assignments: [(String, String)], gps: GPSCoordinate?,
                                 options: WriteOptions) throws {
        let old = before.metadata, new = after.metadata
        guard old.fileType == new.fileType,
              old.dateTags.filter({ !$0.key.hasPrefix("XMP") }) ==
                new.dateTags.filter({ !$0.key.hasPrefix("XMP") }),
              old.dateTimeOriginal == new.dateTimeOriginal,
              old.createDate == new.createDate,
              old.modifyDate == new.modifyDate else {
            throw PhotoError("EXIF 日期或拍攝時間發生變化；候選檔已拒絕。")
        }
        let actual = after.embeddedTags
        let allowedChanges = Set(assignments.map(\.0))
        let keys = Set(before.embeddedTags.keys).union(actual.keys)
        for key in keys where before.embeddedTags[key] != actual[key] {
            if allowedChanges.contains(key) || allowedChanges.contains(canonicalCopyKey(key)) { continue }
            let parts = key.split(separator: ":")
            let gpsTag = String(parts.last ?? "")
            if gps != nil, parts.first == "GPS",
               ["GPSVersionID", "GPSLatitude", "GPSLatitudeRef", "GPSLongitude", "GPSLongitudeRef",
                "GPSAltitude", "GPSAltitudeRef"].contains(gpsTag) {
                continue
            }
            if key == "IFD0:GPSInfo" || key == "IFD0:GPSInfoIFDPointer" {
                guard gps != nil, let updated = actual[key],
                      validPointers(updated, limit: new.fileSize) else {
                    throw PhotoError("GPS 結構位址無法驗證：\(key)。")
                }
                continue
            }
            if permittedStructuralSpanChange(key, before: before.embeddedTags, after: actual,
                    metadata: old, options: options, oldLimit: old.fileSize,
                    newLimit: new.fileSize) { continue }
            if let prior = before.embeddedTags[key], let updated = actual[key],
               permittedPointer(key, metadata: old, options: options),
               validPointers(prior, limit: old.fileSize),
               validPointers(updated, limit: new.fileSize),
               pointerCount(prior) == pointerCount(updated) { continue }
            throw PhotoError("非目標 metadata 變動：\(key)；候選檔已拒絕。")
        }
        try verifyAssignedValues(assignments, in: actual)
        if let gps {
            func signed(_ value: String?, ref: String?, negativeRef: String) -> Double? {
                guard let value, let number = Double(value) else { return nil }
                return ref?.uppercased() == negativeRef ? -abs(number) : abs(number)
            }
            guard let latitude = signed(new.gpsLatitude, ref: new.gpsLatitudeRef, negativeRef: "S"),
                  let longitude = signed(new.gpsLongitude, ref: new.gpsLongitudeRef, negativeRef: "W"),
                  abs(latitude - gps.latitude) < 0.000001,
                  abs(longitude - gps.longitude) < 0.000001 else {
                throw PhotoError("EXIF GPS 寫入後讀回值不符；候選檔已拒絕。")
            }
            if let altitude = gps.altitudeMeters {
                guard let raw = new.gpsAltitude, let value = Double(raw),
                      abs((new.gpsAltitudeRef == "1" ? -abs(value) : abs(value)) - altitude) < 0.02 else {
                    throw PhotoError("EXIF GPS 高度驗證失敗：\(new.gpsAltitude ?? "缺少") / \(new.gpsAltitudeRef ?? "缺少")；候選檔已拒絕。")
                }
            } else if new.gpsAltitude != nil || new.gpsAltitudeRef != nil {
                throw PhotoError("GPS 高度沒有清除；候選檔已拒絕。")
            }
            if assignments.contains(where: { $0.0 == "XMP-exif:GPSLatitude" }) {
                try verifyXMPCoordinate(tags: actual.filter { $0.key.hasPrefix("XMP") }, coordinate: gps)
            }
            try verifyEXIFCoordinate(tags: actual, coordinate: gps)
        }
        let oldWarnings = Set(before.warnings.split(separator: "\n").map(String.init))
        let introduced = Set(after.warnings.split(separator: "\n").map(String.init)).subtracting(oldWarnings)
        guard introduced.isEmpty else {
            throw PhotoError("寫入後新增 ExifTool 警告：\(introduced.sorted().joined(separator: "; "))")
        }
    }

    static func verifyXMPCoordinate(tags: [String: String], coordinate: GPSCoordinate) throws {
        func number(_ raw: String) -> Double? {
            guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8),
                      options: [.fragmentsAllowed]) else { return nil }
            if let number = value as? NSNumber { return number.doubleValue }
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Double(trimmed) { return value }
            // ExifTool may render XMP GPS as decimal degrees with a direction.
            let parts = trimmed.split(separator: " ")
            guard parts.count == 2, let value = Double(parts[0]) else { return nil }
            return ["S", "W"].contains(String(parts[1]).uppercased()) ? -abs(value) : abs(value)
        }
        func values(_ key: String) -> [Double?] {
            tags.filter { canonicalCopyKey($0.key) == key }.map { number($0.value) }
        }
        let latitudes = values("XMP-exif:GPSLatitude")
        let longitudes = values("XMP-exif:GPSLongitude")
        guard !latitudes.isEmpty, !longitudes.isEmpty,
              latitudes.allSatisfy({ $0.map { abs($0 - coordinate.latitude) < 0.000001 } == true }),
              longitudes.allSatisfy({ $0.map { abs($0 - coordinate.longitude) < 0.000001 } == true }) else {
            throw PhotoError("XMP GPS 寫入後讀回值不符；候選檔已拒絕。")
        }
        let altitudes = values("XMP-exif:GPSAltitude")
        if let altitude = coordinate.altitudeMeters {
            guard !altitudes.isEmpty,
                  altitudes.allSatisfy({ $0.map { abs(abs($0) - abs(altitude)) < 0.02 } == true }) else {
                throw PhotoError("XMP GPS 高度讀回值不符；候選檔已拒絕。")
            }
            let references = tags.filter { canonicalCopyKey($0.key) == "XMP-exif:GPSAltitudeRef" }
                .compactMap { raw -> String? in
                    let value = try? JSONSerialization.jsonObject(with: Data(raw.value.utf8), options: [.fragmentsAllowed])
                    if let number = value as? NSNumber { return number.stringValue }
                    return value as? String
                }
            guard !references.isEmpty, references.allSatisfy({ $0 == coordinate.altitudeRef }) else {
                throw PhotoError("XMP GPS 高度方向讀回值不符；候選檔已拒絕。")
            }
        } else if !altitudes.isEmpty || tags.keys.contains(where: {
            canonicalCopyKey($0) == "XMP-exif:GPSAltitudeRef"
        }) {
            throw PhotoError("XMP GPS 舊高度沒有清除；候選檔已拒絕。")
        }
    }

    static func verifyEXIFCoordinate(tags: [String: String], coordinate: GPSCoordinate) throws {
        func values(_ name: String) -> [String?] {
            tags.filter { canonicalCopyKey($0.key) == "GPS:\(name)" }.map { raw in
                guard let value = try? JSONSerialization.jsonObject(with: Data(raw.value.utf8),
                    options: [.fragmentsAllowed]) else { return nil }
                if let number = value as? NSNumber { return number.stringValue }
                return value as? String
            }
        }
        for (name, target) in [("GPSLatitude", abs(coordinate.latitude)),
                               ("GPSLongitude", abs(coordinate.longitude))] {
            let found = values(name)
            guard !found.isEmpty, found.allSatisfy({ $0.flatMap(Double.init).map { abs($0 - target) < 0.000001 } == true }) else {
                throw PhotoError("EXIF \(name) 有未同步的副本；候選檔已拒絕。")
            }
        }
        for (name, target) in [("GPSLatitudeRef", coordinate.latitudeRef),
                               ("GPSLongitudeRef", coordinate.longitudeRef)] {
            let found = values(name)
            guard !found.isEmpty, found.allSatisfy({ $0?.uppercased() == target }) else {
                throw PhotoError("EXIF \(name) 有未同步的副本；候選檔已拒絕。")
            }
        }
    }

    static func verifyAssignedValues(_ assignments: [(String, String)], in tags: [String: String]) throws {
        for (key, expected) in assignments {
            let actualValues = tags.filter { canonicalCopyKey($0.key) == key }.map { raw -> String? in
                (try? JSONSerialization.jsonObject(with: Data(raw.value.utf8), options: [.fragmentsAllowed])) as? String
            }
            if expected.isEmpty {
                guard actualValues.isEmpty else { throw PhotoError("目標欄位未清除：\(key)。") }
            } else if key.hasPrefix("ExifIFD:OffsetTime") {
                guard !actualValues.isEmpty, actualValues.allSatisfy({ $0 == expected }) else {
                    throw PhotoError("EXIF 時區讀回值不符：\(key)。")
                }
            } else if key.hasPrefix("XMP") &&
                ["DateTimeOriginal", "CreateDate", "ModifyDate", "DateCreated"]
                    .contains(String(key.split(separator: ":").last ?? "")) {
                guard !actualValues.isEmpty else { throw PhotoError("XMP 日期未寫入：\(key)。") }
                let expectedOffset = String(expected.suffix(6))
                let expectedLocal = String(expected.dropLast(6))
                func normalized(_ value: String) -> String {
                    value.replacingOccurrences(of: "-", with: ":")
                        .replacingOccurrences(of: "T", with: " ")
                }
                for actual in actualValues {
                    guard let actual else { throw PhotoError("XMP 日期無法讀回：\(key)。") }
                    let actualOffset = actual.hasSuffix("Z") ? "+00:00" : String(actual.suffix(6))
                    let actualLocal = String(actual.dropLast(actual.hasSuffix("Z") ? 1 : 6))
                    guard actualOffset == expectedOffset,
                          normalized(actualLocal) == normalized(expectedLocal) else {
                        throw PhotoError("XMP 日期或時區讀回值不符：\(key)；預期 \(expected)，實際 \(actual)。")
                    }
                }
            }
        }
    }

    static func verify(before: ExifTool.Snapshot, after: ExifTool.Snapshot,
                       assignments: [(String, String)], options: WriteOptions) throws -> [String] {
        let old = before.metadata, new = after.metadata
        guard old.fileType == new.fileType, old.dateTags == new.dateTags,
              old.dateTimeOriginal == new.dateTimeOriginal, old.createDate == new.createDate,
              old.modifyDate == new.modifyDate else {
            throw PhotoError("Capture/create/modify dates or subsecond fields changed; candidate was rejected.")
        }
        var expected = before.embeddedTags
        for (tag, value) in assignments {
            expected["ExifIFD:\(tag)"] = String(decoding: try JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        let actual = after.embeddedTags
        let changed = Set(expected.keys).union(actual.keys).filter { expected[$0] != actual[$0] }.sorted()
        var relocations: [String] = []
        for key in changed {
            if permittedStructuralSpanChange(
                key, before: expected, after: actual, metadata: old, options: options,
                oldLimit: old.fileSize, newLimit: new.fileSize
            ), let updated = actual[key] {
                expected[key] = updated
                relocations.append(key)
                continue
            }
            if let prior = expected[key], let updated = actual[key],
               permittedPointer(key, metadata: old, options: options) {
                let oldValid = validPointers(prior, limit: old.fileSize)
                let newValid = validPointers(updated, limit: new.fileSize)
                let sameCount = pointerCount(prior) == pointerCount(updated)
                guard oldValid, newValid, sameCount else {
                    throw PhotoError(
                        "Pointer relocation failed validation: \(key). " +
                        "before[\(pointerSummary(prior, limit: old.fileSize))] " +
                        "after[\(pointerSummary(updated, limit: new.fileSize))] " +
                        "sameCount=\(sameCount). Candidate was rejected; original not changed."
                    )
                }
                expected[key] = updated
                relocations.append(key)
                continue
            }
            throw PhotoError("Non-offset metadata changed: \(key). Candidate was rejected; original not changed.")
        }
        guard expected == actual else { throw PhotoError("Metadata verification did not match the authorized operation.") }
        // Existing source warnings are reported, but a new warning is never accepted silently.
        let previousWarnings = Set(before.warnings.split(separator: "\n").map(String.init))
        let newWarnings = Set(after.warnings.split(separator: "\n").map(String.init)).subtracting(previousWarnings)
        guard newWarnings.isEmpty else {
            throw PhotoError("New ExifTool warning after writing: \(newWarnings.sorted().joined(separator: "; "))")
        }
        if relocations.isEmpty { return [] }
        return ["Metadata-only verification: layout pointers relocated (\(relocations.joined(separator: ", "))). Image and private binary bytes were not hashed."]
    }

    static func verifyGPSAddition(before: ExifTool.Snapshot, after: ExifTool.Snapshot,
                                  location: GPSCoordinate, options: WriteOptions) throws -> [String] {
        let old = before.metadata, new = after.metadata
        guard old.fileType == new.fileType, old.dateTags == new.dateTags,
              old.dateTimeOriginal == new.dateTimeOriginal, old.createDate == new.createDate,
              old.modifyDate == new.modifyDate else {
            throw PhotoError("GPS 寫入時日期、時間或次秒欄位發生變化；候選檔已拒絕，原檔未更動。")
        }
        guard !old.hasAnyGPS else {
            throw PhotoError("照片已含 GPS 資訊；為避免覆寫既有位置資料，未新增 GPS。")
        }

        func signed(_ value: String?, ref: String?, negativeRef: String) -> Double? {
            guard let value, let number = Double(value) else { return nil }
            return ref?.uppercased() == negativeRef ? -abs(number) : abs(number)
        }
        guard let latitude = signed(new.gpsLatitude, ref: new.gpsLatitudeRef, negativeRef: "S"),
              let longitude = signed(new.gpsLongitude, ref: new.gpsLongitudeRef, negativeRef: "W"),
              abs(latitude - location.latitude) <= 0.0000002,
              abs(longitude - location.longitude) <= 0.0000002 else {
            throw PhotoError("GPS 經緯度寫入後讀回值不符；候選檔已拒絕，原檔未更動。")
        }
        if let expectedAltitude = location.altitudeMeters {
            guard let raw = new.gpsAltitude, let altitude = Double(raw) else {
                throw PhotoError("GPS 高度寫入後無法讀回；候選檔已拒絕，原檔未更動。")
            }
            let signedAltitude = (new.gpsAltitudeRef == "1") ? -abs(altitude) : abs(altitude)
            guard abs(signedAltitude - expectedAltitude) <= 0.01 else {
                throw PhotoError("GPS 高度寫入後讀回值不符；候選檔已拒絕，原檔未更動。")
            }
        }

        var expected = before.embeddedTags
        let actual = after.embeddedTags
        let changed = Set(expected.keys).union(actual.keys).filter { expected[$0] != actual[$0] }.sorted()
        let allowedGPS: Set<String> = [
            "GPSVersionID", "GPSLatitude", "GPSLatitudeRef", "GPSLongitude", "GPSLongitudeRef",
            "GPSAltitude", "GPSAltitudeRef"
        ]
        var relocations: [String] = []
        for key in changed {
            let parts = key.split(separator: ":")
            let group = parts.first.map(String.init) ?? ""
            let tag = parts.last.map(String.init) ?? ""

            if group == "GPS" && allowedGPS.contains(tag), let value = actual[key] {
                expected[key] = value
                continue
            }
            if group == "IFD0", ["GPSInfo", "GPSInfoIFDPointer"].contains(tag),
               expected[key] == nil, let updated = actual[key],
               validPointers(updated, limit: new.fileSize) {
                expected[key] = updated
                relocations.append(key)
                continue
            }
            if permittedStructuralSpanChange(
                key, before: expected, after: actual, metadata: old, options: options,
                oldLimit: old.fileSize, newLimit: new.fileSize
            ), let updated = actual[key] {
                expected[key] = updated
                relocations.append(key)
                continue
            }
            if let prior = expected[key], let updated = actual[key],
               permittedPointer(key, metadata: old, options: options) {
                let oldValid = validPointers(prior, limit: old.fileSize)
                let newValid = validPointers(updated, limit: new.fileSize)
                let sameCount = pointerCount(prior) == pointerCount(updated)
                guard oldValid, newValid, sameCount else {
                    throw PhotoError(
                        "GPS 結構位址驗證失敗：\(key)。" +
                        "before[\(pointerSummary(prior, limit: old.fileSize))] " +
                        "after[\(pointerSummary(updated, limit: new.fileSize))] " +
                        "sameCount=\(sameCount)。候選檔已拒絕，原檔未更動。"
                    )
                }
                expected[key] = updated
                relocations.append(key)
                continue
            }
            throw PhotoError("GPS 以外的中繼資料發生變化：\(key)。候選檔已拒絕，原檔未更動。")
        }
        guard expected == actual else {
            throw PhotoError("GPS 寫入後的中繼資料驗證不一致；候選檔已拒絕，原檔未更動。")
        }

        let previousWarnings = Set(before.warnings.split(separator: "\n").map(String.init))
        let newWarnings = Set(after.warnings.split(separator: "\n").map(String.init)).subtracting(previousWarnings)
        guard newWarnings.isEmpty else {
            throw PhotoError("GPS 寫入後出現新的 ExifTool 警告：\(newWarnings.sorted().joined(separator: "; "))")
        }
        if relocations.isEmpty { return [] }
        return ["GPS metadata verified; layout pointers relocated (\(relocations.joined(separator: ", "))). Image and private binary bytes were not hashed."]
    }

    private static func permittedPointer(_ key: String, metadata: PhotoMetadata, options: WriteOptions) -> Bool {
        let components = key.split(separator: ":")
        guard components.count == 2 else { return false }
        let group = String(components[0]), tag = String(components[1])
        let sony = metadata.make?.uppercased() == "SONY"
        if sony && !options.sonyCompatibility { return false }
        if metadata.fileType == "JPEG", key == "IFD1:ThumbnailOffset" { return true }
        if metadata.fileType == "TIFF", (group.hasPrefix("IFD") || group.hasPrefix("SubIFD")),
           ["StripOffsets", "TileOffsets", "ThumbnailOffset"].contains(tag) { return true }
        // ExifTool may relocate embedded preview/JPEG payloads when a TIFF-based
        // Sony RAW file gains EXIF fields. These values are offsets, not payload
        // metadata: accept only the explicit pointer tags below, and only after
        // verifying that both old/new offsets remain inside their respective files.
        let sonyPointers: Set<String> = ["MPImage2:MPImageStart", "IFD0:PreviewImageStart",
            "IFD1:ThumbnailOffset", "IFD2:JpgFromRawStart", "Sony:HiddenDataOffset",
            "SR2:SR2SubIFDOffset", "SubIFD:StripOffsets", "SubIFD:TileOffsets"]
        return sony && options.sonyCompatibility && sonyPointers.contains(key)
    }

    /// Sony ARW contains a small set of private blocks described by explicit
    /// offset/length pairs. ExifTool may relocate/rebuild these containers while
    /// preserving all decoded tags. Treat only the exact pairs below as structural,
    /// and require both old/new spans to remain fully inside their respective files.
    private static func permittedStructuralSpanChange(
        _ key: String, before: [String: String], after: [String: String],
        metadata: PhotoMetadata, options: WriteOptions,
        oldLimit: Int64?, newLimit: Int64?
    ) -> Bool {
        guard metadata.make?.uppercased() == "SONY", options.sonyCompatibility else {
            return false
        }
        let pair: (offset: String, length: String)
        switch key {
        case "SR2:SR2SubIFDLength":
            pair = ("SR2:SR2SubIFDOffset", "SR2:SR2SubIFDLength")
        case "Sony:HiddenDataLength":
            pair = ("Sony:HiddenDataOffset", "Sony:HiddenDataLength")
        default:
            return false
        }
        guard let oldOffset = before[pair.offset], let oldLength = before[pair.length],
              let newOffset = after[pair.offset], let newLength = after[pair.length] else {
            return false
        }
        return validSpan(offset: oldOffset, length: oldLength, limit: oldLimit)
            && validSpan(offset: newOffset, length: newLength, limit: newLimit)
    }

    private static func pointerValues(_ canonical: String) -> [Int64]? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(canonical.utf8), options: [.fragmentsAllowed]) else { return nil }
        func integer(_ number: NSNumber) -> Int64? {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int64(number.stringValue)
        }
        if let number = value as? NSNumber { return integer(number).map { [$0] } }
        if let numbers = value as? [NSNumber] {
            let values = numbers.compactMap(integer)
            return values.count == numbers.count ? values : nil
        }
        if let text = value as? String {
            let parts = text.split { $0.isWhitespace || $0 == "," }
            let values = parts.compactMap { Int64($0) }
            return values.count == parts.count && !values.isEmpty ? values : nil
        }
        return nil
    }
    private static func pointerSummary(_ value: String, limit: Int64?) -> String {
        guard let values = pointerValues(value), !values.isEmpty else {
            let sample = String(value.prefix(96)).replacingOccurrences(of: "\n", with: "\\n")
            return "unparsed; canonical=\(sample)"
        }
        let minimum = values.min() ?? -1
        let maximum = values.max() ?? -1
        let bound = limit.map(String.init) ?? "nil"
        let inRange = limit.map { fileSize in
            values.allSatisfy { $0 >= 0 && $0 < fileSize }
        } ?? false
        return "count=\(values.count), min=\(minimum), max=\(maximum), fileSize=\(bound), inRange=\(inRange)"
    }

    private static func pointerCount(_ value: String) -> Int { pointerValues(value)?.count ?? 0 }
    private static func scalarInteger(_ value: String) -> Int64? {
        guard let values = pointerValues(value), values.count == 1 else { return nil }
        return values[0]
    }
    private static func validPointers(_ value: String, limit: Int64?) -> Bool {
        guard let limit, let values = pointerValues(value), !values.isEmpty else { return false }
        return values.allSatisfy { $0 >= 0 && $0 < limit }
    }
    private static func validSpan(offset: String, length: String, limit: Int64?) -> Bool {
        guard let limit, limit >= 0,
              let start = scalarInteger(offset), let count = scalarInteger(length),
              start >= 0, count >= 0, start <= limit, count <= limit - start else {
            return false
        }
        return true
    }
}
