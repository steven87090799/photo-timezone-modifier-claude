import Foundation
import Testing
@testable import PhotoTimezoneApp

@Suite(.serialized)
@MainActor
struct CompressionPreferencesTests {
    @Test func damagedLegacyQualityIsSafeForEveryInitialFormat() throws {
        for format in CompressionFormat.allCases {
            let name = "CompressionLegacyPreferences-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(format.rawValue, forKey: "nativeCompressionFormat")
            defaults.set(Double.nan, forKey: "nativeCompressionQuality")
            let model = CompressionModel(defaults: defaults)
            #expect(model.quality.isFinite)
            #expect((1...100).contains(Int(model.quality.rounded())))
            model.host.shutdown()
        }
    }

    @Test func damagedStoredQualityCannotCrashPreviewOrBatchIntegerConversion() throws {
        let name = "CompressionPreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Double.nan, forKey: "nativeCompressionQuality.jpg")
        defaults.set(Double.infinity, forKey: "nativeCompressionQuality.png")
        let model = CompressionModel(defaults: defaults)
        defer { model.host.shutdown() }
        #expect(model.quality == 86)
        #expect(Int(model.quality.rounded()) == 86)
        model.format = .png
        #expect(model.quality == model.format.recommendedQuality)
        model.quality = .nan
        #expect(model.quality.isFinite)
        #expect(Int(model.quality.rounded()) == 82)
        model.quality = 10000
        #expect(model.quality == 100)
        model.quality = -10
        #expect(model.quality == 1)
        model.format = .jpeg
        #expect(model.quality == 86)
    }
}
