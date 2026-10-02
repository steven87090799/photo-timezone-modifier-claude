import Foundation
import CoreFoundation

/// Metadata-only verification chosen by the user. No photo, preview, thumbnail,
/// or MakerNotes digest is calculated. Unknown binary payloads are NOT certified.
enum MetadataVerifier {
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
            guard let prior = expected[key], let updated = actual[key],
                  permittedPointer(key, metadata: old, options: options),
                  validPointers(prior, limit: old.fileSize), validPointers(updated, limit: new.fileSize),
                  pointerCount(prior) == pointerCount(updated) else {
                throw PhotoError("Non-offset metadata changed: \(key). Candidate was rejected; original not changed.")
            }
            expected[key] = updated
            relocations.append(key)
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
               permittedPointer(key, metadata: old, options: options),
               validPointers(prior, limit: old.fileSize), validPointers(updated, limit: new.fileSize),
               pointerCount(prior) == pointerCount(updated) {
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
            "IFD1:ThumbnailOffset", "IFD2:JpgFromRawStart",
            "SR2:SR2SubIFDOffset", "SubIFD:StripOffsets"]
        return sony && options.sonyCompatibility && sonyPointers.contains(key)
    }

    /// Sony ARW embeds an encrypted SR2 private IFD described by an offset/length
    /// pair. ExifTool may rebuild that block while preserving all decoded tags.
    /// Treat only this exact structural length as relocatable, and require both
    /// the old and new spans to remain fully inside their respective files.
    private static func permittedStructuralSpanChange(
        _ key: String, before: [String: String], after: [String: String],
        metadata: PhotoMetadata, options: WriteOptions,
        oldLimit: Int64?, newLimit: Int64?
    ) -> Bool {
        guard key == "SR2:SR2SubIFDLength",
              metadata.make?.uppercased() == "SONY", options.sonyCompatibility,
              let oldOffset = before["SR2:SR2SubIFDOffset"],
              let oldLength = before["SR2:SR2SubIFDLength"],
              let newOffset = after["SR2:SR2SubIFDOffset"],
              let newLength = after["SR2:SR2SubIFDLength"] else {
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
            let parts = text.split(separator: " ")
            let values = parts.compactMap { Int64($0) }
            return values.count == parts.count && !values.isEmpty ? values : nil
        }
        return nil
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
