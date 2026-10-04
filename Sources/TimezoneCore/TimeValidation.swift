import Foundation

public enum TimeValidation {
    /// Existing metadata may use minute offsets outside the GUI's 15-minute grid,
    /// but the EXIF/UI safety range is fixed to UTC-12:00 ... UTC+14:00.
    public static func isOffset(_ value: String?) -> Bool {
        guard let value else { return false }
        let bytes = Array(value.utf8)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
              [1, 2, 4, 5].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
        let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let minutes = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        guard minutes < 60 else { return false }
        if bytes[0] == 45 {
            return hours < 12 || (hours == 12 && minutes == 0)
        }
        return hours < 14 || (hours == 14 && minutes == 0)
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
            throw PhotoError("EXIF 拍攝日期（DateTimeOriginal）缺漏或格式無效；日期與時間未修補或變更。")
        }
        let offsets = [metadata.offsetOriginal, metadata.offsetDigitized, metadata.offsetTime]
        for value in offsets where value != nil && !isOffset(value) {
            guard mode == .replaceAll else {
                throw PhotoError("現有 EXIF 時區偏移格式無效。請明確選擇覆寫時區；只補缺漏模式不會覆寫原值。")
            }
        }
    }

    /// Diagnostic only: never translate the wall-clock time or rewrite XMP.
    static func issues(_ metadata: PhotoMetadata, dates: [String: String]? = nil) -> [String] {
        var result: [String] = []
        let dates = dates ?? metadata.dateTags
        let populatedOffsets: [(String, String)] = [
            ("OffsetTimeOriginal", metadata.offsetOriginal),
            ("OffsetTimeDigitized", metadata.offsetDigitized),
            ("OffsetTime", metadata.offsetTime)
        ].compactMap { name, value in value.map { (name, $0) } }
        if Set(populatedOffsets.map(\.1)).count > 1 {
            result.append("EXIF 時區欄位不一致：" +
                populatedOffsets.map { "\($0.0)=\($0.1)" }.joined(separator: ", ") +
                "；已保留原值，未自動統一時區。")
        }
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
                        result.append("\(key) 已記錄時區，但對應的 EXIF 時區缺漏；XMP 保持原值。")
                    }
                    continue
                }
                if value.hasSuffix("Z") {
                    if offset != "+00:00" && offset != "-00:00" {
                        result.append("\(key) 記錄為 UTC，但 EXIF 時區偏移為 \(offset)；XMP 保持原值。")
                    }
                } else if isOffset(suffix), suffix != offset {
                    result.append("\(key) 的時區偏移 \(suffix) 與 EXIF 時區 \(offset) 不一致；XMP 保持原值。")
                }
                let local = String(value.prefix(19)).replacingOccurrences(of: "T", with: " ")
                    .replacingOccurrences(of: "-", with: ":")
                if local != date {
                    result.append("\(key) 的日期與鐘點和 EXIF \(name) 不一致；兩者的日期與時間均未調整。")
                }
            }
        }
        if metadata.createDate == nil || metadata.modifyDate == nil {
            result.append("缺少部分 EXIF 日期（數位化或修改日期）；時區標籤不會補建缺少的日期。")
        }
        return Array(Set(result)).sorted()
    }
}
