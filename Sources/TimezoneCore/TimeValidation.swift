import Foundation

public enum TimeValidation {
    /// Existing metadata may use minute offsets outside the GUI's 15-minute grid.
    public static func isOffset(_ value: String?) -> Bool {
        guard let value else { return false }
        let bytes = Array(value.utf8)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
              [1, 2, 4, 5].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
        let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let minutes = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        return minutes < 60 && (hours < 14 || (hours == 14 && minutes == 0))
    }

    public static func isCaptureDate(_ value: String?) -> Bool {
        guard let value else { return false }
        let b = Array(value.utf8)
        guard b.count == 19, b[4] == 58, b[7] == 58, b[10] == 32,
              b[13] == 58, b[16] == 58 else { return false }
        let positions = [0,1,2,3,5,6,8,9,11,12,14,15,17,18]
        guard positions.allSatisfy({ (48...57).contains(b[$0]) }) else { return false }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(b[$1] - 48) } }
        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        guard year > 0, (1...12).contains(month), day > 0,
              number(11..<13) < 24, number(14..<16) < 60, number(17..<19) < 60 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }

    static func validateForWrite(_ metadata: PhotoMetadata, mode: WriteMode) throws {
        guard isCaptureDate(metadata.dateTimeOriginal) else {
            throw PhotoError("Invalid or missing EXIF DateTimeOriginal; timestamps were not repaired or changed.")
        }
        let offsets = [metadata.offsetOriginal, metadata.offsetDigitized, metadata.offsetTime]
        for value in offsets where value != nil && !isOffset(value) {
            guard mode == .replaceAll else {
                throw PhotoError("Invalid existing EXIF offset. Use an explicitly confirmed offset replacement; fill-missing will not overwrite it.")
            }
        }
    }

    /// Diagnostic only: never translate the wall-clock time or rewrite XMP.
    static func issues(_ metadata: PhotoMetadata, dates: [String: String]? = nil) -> [String] {
        var result: [String] = []
        let dates = dates ?? metadata.dateTags
        let pairs: [(String, String?, String?)] = [
            ("DateTimeOriginal", metadata.dateTimeOriginal, metadata.offsetOriginal),
            ("DateCreated", metadata.dateTimeOriginal, metadata.offsetOriginal),
            ("CreateDate", metadata.createDate, metadata.offsetDigitized),
            ("ModifyDate", metadata.modifyDate, metadata.offsetTime)
        ]
        for (name, date, offset) in pairs {
            guard let date else { continue }
            for (key, value) in dates where key.hasPrefix("XMP") && key.split(separator: ":").last == Substring(name) {
                let suffix = String(value.suffix(6))
                guard let offset else {
                    if value.hasSuffix("Z") || isOffset(suffix) {
                        result.append("\(key) has a timezone but its EXIF counterpart is missing; XMP was left unchanged.")
                    }
                    continue
                }
                if value.hasSuffix("Z") {
                    if offset != "+00:00" && offset != "-00:00" {
                        result.append("\(key) is UTC but EXIF offset is \(offset); XMP was left unchanged.")
                    }
                } else if isOffset(suffix), suffix != offset {
                    result.append("\(key) offset \(suffix) conflicts with EXIF \(offset); XMP was left unchanged.")
                }
                let local = String(value.prefix(19)).replacingOccurrences(of: "T", with: " ")
                    .replacingOccurrences(of: "-", with: ":")
                if local != date {
                    result.append("\(key) wall-clock time differs from EXIF \(name); neither timestamp was adjusted.")
                }
            }
        }
        if metadata.createDate == nil || metadata.modifyDate == nil {
            result.append("One or more associated EXIF dates are absent. Offset tags do not create missing dates.")
        }
        return Array(Set(result)).sorted()
    }
}
