import Testing
@testable import TimezoneCore

@Suite struct OffsetGuideTests {
    @Test func wholeHourChoicesAreCompactAndComplete() {
        #expect(OffsetGuide.wholeHours.count == 27)
        #expect(OffsetGuide.wholeHours.first?.minutes == -720)
        #expect(OffsetGuide.wholeHours.last?.minutes == 840)
        #expect(OffsetGuide.wholeHours.allSatisfy { $0.minutes.isMultiple(of: 60) })
        #expect(OffsetGuide.wholeHours.allSatisfy { !OffsetGuide.examples(for: $0).isEmpty })
    }

    @Test func quarterHourExamplesAreClearlyLabeled() {
        #expect(OffsetGuide.examples(for: UTCOffset(minutes: 480)).contains("台灣"))
        #expect(OffsetGuide.examples(for: UTCOffset(minutes: 345)).contains("尼泊爾"))
        #expect(OffsetGuide.examples(for: UTCOffset(minutes: -210)).contains("紐芬蘭"))
        #expect(OffsetGuide.examples(for: UTCOffset(minutes: 765)).contains("查塔姆"))
        #expect(OffsetGuide.examples(for: UTCOffset(minutes: 15)).contains("沒有常見"))
    }
}
