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

    private static func permittedPointer(_ key: String, metadata: PhotoMetadata, options: WriteOptions) -> Bool {
        let components = key.split(separator: ":")
        guard components.count == 2 else { return false }
        let group = String(components[0]), tag = String(components[1])
        let sony = metadata.make?.uppercased() == "SONY"
        if sony && !options.sonyCompatibility { return false }
        if metadata.fileType == "JPEG", key == "IFD1:ThumbnailOffset" { return true }
        if metadata.fileType == "TIFF", (group.hasPrefix("IFD") || group.hasPrefix("SubIFD")),
           ["StripOffsets", "TileOffsets", "ThumbnailOffset"].contains(tag) { return true }
        let sonyPointers: Set<String> = ["MPImage2:MPImageStart", "IFD0:PreviewImageStart",
            "IFD1:ThumbnailOffset", "SR2:SR2SubIFDOffset", "SubIFD:StripOffsets"]
        return sony && options.sonyCompatibility && sonyPointers.contains(key)
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
    private static func validPointers(_ value: String, limit: Int64?) -> Bool {
        guard let limit, let values = pointerValues(value), !values.isEmpty else { return false }
        return values.allSatisfy { $0 >= 0 && $0 < limit }
    }
}
