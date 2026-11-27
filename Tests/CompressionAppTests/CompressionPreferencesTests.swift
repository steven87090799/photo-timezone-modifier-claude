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

    @Test func legacyWebhookURLIsClearedAndNewCredentialsStayInMemory() throws {
        let name = "WebhookPreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("https://example.invalid/?key=fake-stored-value", forKey: "nativeCompressionWebhookURL")
        let model = CompressionModel(defaults: defaults)
        defer { model.host.shutdown() }
        #expect(model.webhookURL.isEmpty)
        #expect(!model.webhookEnabled)
        #expect(defaults.object(forKey: "nativeCompressionWebhookURL") == nil)
        model.webhookURL = "https://example.invalid/?key=fake-new-value"
        model.webhookToken = "fake-token"
        #expect(defaults.object(forKey: "nativeCompressionWebhookURL") == nil)
        #expect(!String(describing: defaults.persistentDomain(forName: name)).contains("fake-"))
    }

    @Test func failedAndCancelledReprocessingKeepThePriorOutput() async throws {
        let name = "Reprocessing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CompressionModel(defaults: defaults)
        defer { model.host.shutdown() }
        let folder = model.host.workDirectory.appendingPathComponent("previous")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let output = folder.appendingPathComponent("output.png")
        let bytes = Data("prior-result".utf8)
        try bytes.write(to: output)
        let missingInput = model.host.workDirectory.appendingPathComponent("missing.jpg")
        var item = CompressionItem(id: UUID(), source: missingInput, originalBytes: 128, width: 8, height: 4)
        item.state = .success; item.format = .png; item.quality = 82
        item.result = CompressionEngineResult(url: output, bytes: Int64(bytes.count), width: 8, height: 4,
                                              metadataStatus: "", frames: 1)
        model.items = [item]
        model.start()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isRunning)
        #expect(model.completed.first?.result?.url == output)
        #expect(model.completed.first?.outputName == "missing.png")
        #expect(model.items.first?.reprocessingFailed == true)
        model.retryFailed()
        model.cancel()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isRunning)
        #expect(model.completed.first?.result?.url == output)
        #expect(try Data(contentsOf: output) == bytes)
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
