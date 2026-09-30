import Testing
@testable import TimezoneCore

@Suite(.serialized)
final class UTCOffsetTests {
    @Test func testEveryQuarterHourFromMinusTwelveThroughPlusFourteenAppearsExactlyOnce() {
        let offsets = UTCOffset.all
        expectEqual(offsets.count, 105)
        expectEqual(offsets.map(\.minutes), Array(stride(from: -720, through: 840, by: 15)))
        expectEqual(Set(offsets).count, offsets.count)
        expectEqual(Set(offsets.map(\.id)).count, offsets.count)
        expectTrue(offsets.allSatisfy(\.isValid))
        expectEqual(offsets.first?.label, "UTC-12:00")
        expectEqual(offsets.last?.label, "UTC+14:00")
    }

    @Test func testValidityRejectsOutOfRangeAndNonQuarterHourValuesWithoutRounding() {
        for minutes in [-720, -705, -15, 0, 15, 345, 765, 825, 840] {
            expectTrue(UTCOffset(minutes: minutes).isValid, "Expected valid: \(minutes)")
        }
        for minutes in [-1440, -735, -721, -719, -1, 1, 14, 16, 839, 841, 855, 1440] {
            expectFalse(UTCOffset(minutes: minutes).isValid, "Must not round or accept: \(minutes)")
        }
    }

    @Test func testLabelsIncludeSignAndZeroPaddingForWholeHalfAndQuarterHours() {
        let examples: [(Int, String)] = [
            (-720, "-12:00"), (-690, "-11:30"), (-345, "-05:45"),
            (-60, "-01:00"), (-45, "-00:45"), (-15, "-00:15"),
            (0, "+00:00"), (15, "+00:15"), (30, "+00:30"), (45, "+00:45"),
            (60, "+01:00"), (330, "+05:30"), (345, "+05:45"),
            (765, "+12:45"), (840, "+14:00")
        ]
        for (minutes, value) in examples {
            let offset = UTCOffset(minutes: minutes)
            expectEqual(offset.value, value)
            expectEqual(offset.label, "UTC\(value)")
            expectEqual(offset.id, minutes)
        }
    }

    @Test func testEveryFormattedOffsetRoundTripsToItsExactMinutes() throws {
        for offset in UTCOffset.all {
            let value = offset.value
            expectEqual(value.count, 6)
            let parts = value.dropFirst().split(separator: ":")
            expectEqual(parts.count, 2)
            let hours = try requireValue(parts.first.flatMap { Int($0) })
            let minutes = try requireValue(parts.last.flatMap { Int($0) })
            expectTrue([0, 15, 30, 45].contains(minutes))
            let sign = value.first == "-" ? -1 : 1
            expectEqual(sign * (hours * 60 + minutes), offset.minutes)
        }
    }
}
