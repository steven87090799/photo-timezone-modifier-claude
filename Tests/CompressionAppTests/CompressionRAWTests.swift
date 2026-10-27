import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import PhotoTimezoneApp
@testable import TimezoneCore

@Suite(.serialized)
@MainActor
struct CompressionRAWTests {
    private var toolURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/vendor-exiftool/exiftool")
    }

    @Test func decoderSelectionNeverFallsBackAcrossGenerations() throws {
        #expect(try RAWDecoder.version9.supportedVersion(in: [.version8, .version9]) == .version9)
        #expect(try RAWDecoder.version9.supportedVersion(in: [.version8DNG, .version9DNG]) == .version9DNG)
        #expect(try RAWDecoder.version8.supportedVersion(in: [.version8DNG, .version9DNG]) == .version8DNG)
        #expect(throws: PhotoError.self) { try RAWDecoder.version9.supportedVersion(in: [.version8]) }
        #expect(throws: PhotoError.self) { try RAWDecoder.version8.supportedVersion(in: [.version9]) }
    }

    @Test func decoderPreferencesAndCompletedResultsKeepTheirOwnVersion() throws {
        let name = "RAWPreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CompressionModel(defaults: defaults)
        defer { model.host.shutdown() }
        #expect(model.rawDecoder == .version9)
        model.rawDecoder = .version8
        #expect(defaults.string(forKey: "nativeCompressionRAWDecoder") == RAWDecoder.version8.rawValue)
        let source = URL(fileURLWithPath: "/private/tmp/test.ARW")
        var item = CompressionItem(id: UUID(), source: source, originalBytes: 123, width: 8, height: 4)
        item.state = .success; item.format = model.format; item.quality = Int(model.quality)
        let output = URL(fileURLWithPath: "/private/tmp/test-output.jpg")
        item.result = CompressionEngineResult(url: output, bytes: 100, width: 8, height: 4,
            metadataStatus: "", frames: 1, developedSource: URL(fileURLWithPath: "/private/tmp/developed.tiff"), rawDecoder: .version8)
        model.items = [item]; model.selection = item.id
        #expect(model.comparisonOutput == output)
        model.rawDecoder = .version9
        #expect(model.comparisonOutput == nil)
        #expect(model.items[0].result?.rawDecoder == .version8)
        #expect(CompressionRAW.accepts(source))
        #expect(CompressionRAW.accepts(URL(fileURLWithPath: "/tmp/photo.NEF")))
        #expect(CompressionRAW.accepts(URL(fileURLWithPath: "/tmp/photo.DNG")))
        #expect(!CompressionRAW.accepts(URL(fileURLWithPath: "/tmp/photo.jpg")))
    }

    @Test func cancelledDevelopmentDoesNotCreateAnImage() throws {
        let cancellation = CancellationToken(); cancellation.cancel()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-\(UUID()).tiff")
        #expect(throws: CancellationError.self) {
            try CompressionRAW.develop(source: URL(fileURLWithPath: "/missing.ARW"), output: output,
                decoder: .version9, sixteenBit: false, cancellation: cancellation)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func rawMetadataProjectionExcludesSensorLayoutAndEditingRecipes() {
        #expect(RAWMetadataTransfer.includes("ExifIFD:DateTimeOriginal"))
        #expect(RAWMetadataTransfer.includes("ExifIFD:OffsetTimeOriginal"))
        #expect(RAWMetadataTransfer.includes("GPS:GPSLatitude"))
        #expect(RAWMetadataTransfer.includes("XMP-exif:GPSLongitude"))
        #expect(RAWMetadataTransfer.includes("XMP-dc:Subject"))
        for key in ["IFD0:StripOffsets", "IFD0:Orientation", "ExifIFD:ExifImageWidth", "ExifIFD:MakerNoteSony",
                    "Sony:WhiteBalance", "SubIFD:ColorMatrix1", "XMP-crs:Exposure2012", "XMP-private:GPSLatitude"] {
            #expect(!RAWMetadataTransfer.includes(key), "\(key) is not portable photographic metadata")
        }
        #expect(!CompressionMetadataTransfer.isPreservedMetadataKey("IFD0:Predictor", preservePhotoEXIF: true))
        #expect(CompressionMetadataTransfer.isPreservedMetadataKey("XMP-private:Predictor", preservePhotoEXIF: true))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"] != nil))
    func realARWChecksDecoderSupportAndAllSixOutputFormats() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RAWCompression-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("旅遊.ARW")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: source)
        let tool = ExifTool(url: toolURL)
        let write = try tool.execute(["-overwrite_original", "-OffsetTimeOriginal=+05:45", "-GPSLatitude=25.033",
            "-GPSLatitudeRef=N", "-GPSLongitude=121.5654", "-GPSLongitudeRef=E", source.path])
        #expect(write.status == 0)
        let original = try Data(contentsOf: source)
        let before = try tool.snapshot(source, strictOffsets: false, forCompression: true)
        let host = CompressionHost(); defer { host.shutdown() }
        _ = NSApplication.shared
        let supported = try #require(CIRAWFilter(imageURL: source)).supportedDecoderVersions
        for decoder in RAWDecoder.allCases {
            if (try? decoder.supportedVersion(in: supported)) == nil {
                do {
                    _ = try await host.perform(source: source, format: .jpeg, quality: 86, preview: false, rawDecoder: decoder)
                    Issue.record("Unsupported RAW decoder was silently replaced")
                } catch { #expect(error.localizedDescription.contains("不支援 \(decoder.rawValue)")) }
                continue
            }
            for format in CompressionFormat.allCases {
                FileHandle.standardError.write(Data("RAW integration: \(decoder.rawValue) → \(format.rawValue)\n".utf8))
                let result = try await host.perform(source: source, format: format,
                    quality: format == .jxl ? 100 : 82, preview: false, rawDecoder: decoder)
                #expect(result.rawDecoder == decoder)
                let developed = try #require(result.developedSource)
                let depth = CompressionImages.sourceDepth(developed)
                #expect(depth == (format == .png || format == .jxl ? 16 : 8))
                #expect(result.width > 1000 && result.height > 1000)
                let after = try tool.snapshot(result.url, strictOffsets: false, forCompression: true)
                #expect(after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal)
                #expect(after.metadata.offsetOriginal == "+05:45")
                #expect(after.metadata.gpsLatitude == before.metadata.gpsLatitude)
                #expect(after.metadata.gpsLongitude == before.metadata.gpsLongitude)
                #expect(try CompressionMetadataTransfer.exifOrientation(result.url, exiftoolURL: toolURL) == 1)
                if format == .png || format == .jxl {
                    try CompressionValidation.verifyLosslessOutput(source: developed, output: result.url)
                }
                #expect(result.metadataStatus.contains(decoder.rawValue))
                #expect(try Data(contentsOf: source) == original)
                try FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
            }
        }
        // Existing sidecar protection also applies to RAW development.
        try Data("<xmp/>".utf8).write(to: source.deletingPathExtension().appendingPathExtension("xmp"))
        await #expect(throws: PhotoError.self) {
            try await host.perform(source: source, format: .jpeg, quality: 86, preview: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.workDirectory.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"] != nil))
    func realARWOrientationIsAppliedBeforeMetadataIsNormalized() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RAWRotation-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rotated = folder.appendingPathComponent("rotated.ARW")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: rotated)
        let tool = ExifTool(url: toolURL)
        for orientation in [1, 3, 6, 8] {
            #expect(try tool.execute(["-overwrite_original", "-EXIF:Orientation#=\(orientation)", rotated.path]).status == 0)
            let output = folder.appendingPathComponent("oriented-\(orientation).tiff")
            let primary = try RAWMetadataTransfer.orientation(rotated, exiftoolURL: toolURL, cancellation: CancellationToken())
            #expect(primary == orientation)
            let size = try CompressionRAW.develop(source: rotated, output: output, decoder: .version8,
                sixteenBit: false, cancellation: CancellationToken(), maxPixel: 120, orientation: primary)
            #expect(orientation >= 5 ? size.width < size.height : size.width > size.height)
            #expect(max(size.width, size.height) <= 121)
            try RAWMetadataTransfer.prepare(source: rotated, developed: output, width: size.width, height: size.height,
                exiftoolURL: toolURL, cancellation: CancellationToken())
            #expect(try CompressionMetadataTransfer.exifOrientation(output, exiftoolURL: toolURL) == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"] != nil))
    func realARWSmallPreviewsUseSelectedDecoderAcrossSixFormats() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_ARW_FIXTURE"])
        let source = URL(fileURLWithPath: path)
        let identity = try FileIdentity.read(source)
        let supported = try #require(CIRAWFilter(imageURL: source)).supportedDecoderVersions
        let host = CompressionHost(); defer { host.shutdown() }
        _ = NSApplication.shared
        for decoder in RAWDecoder.allCases where (try? decoder.supportedVersion(in: supported)) != nil {
            for format in CompressionFormat.allCases {
                let result = try await host.perform(source: source, format: format, quality: 82,
                    preview: true, rawDecoder: decoder)
                #expect(result.rawDecoder == decoder)
                #expect(result.width > 0 && result.height > 0 && max(result.width, result.height) <= 901)
                #expect(result.metadataStatus.contains("未複製中繼資料"))
                try CompressionValidation.verifyOutput(result.url, width: result.width, height: result.height)
                try identity.verify(source)
                try FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
            }
        }
    }

    @Test func projectedTIFFKeepsExactPhotographicValuesInPNGAndAVIF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMetadata-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.tiff"), developed = folder.appendingPathComponent("developed.tiff")
        let context = CIContext(options: [.cacheIntermediates: false])
        var image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
        for (index, color) in [CIColor.red, .green, .blue].enumerated() {
            image = CIImage(color: color).cropped(to: CGRect(x: index * 8, y: 0, width: 8, height: 16)).composited(over: image)
        }
        for file in [source, developed] {
            try context.writeTIFFRepresentation(of: image, to: file, format: .RGBX16,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        }
        let tool = ExifTool(url: toolURL)
        #expect(try tool.execute(["-overwrite_original", "-DateTimeOriginal=2026:10:27 12:34:56",
            "-OffsetTimeOriginal=+05:45", "-GPSLatitude=25.033", "-GPSLatitudeRef=N",
            "-GPSLongitude=121.5654", "-GPSLongitudeRef=E", "-MaxApertureValue#=4.49390226933208", source.path]).status == 0)
        let token = CancellationToken()
        try RAWMetadataTransfer.prepare(source: source, developed: developed, width: 32, height: 16,
            exiftoolURL: toolURL, cancellation: token)
        let host = CompressionHost(); defer { host.shutdown() }
        let result = try await host.perform(source: developed, format: .png, quality: 82, preview: false)
        let before = try tool.snapshot(source, strictOffsets: false, forCompression: true)
        let after = try tool.snapshot(result.url, strictOffsets: false, forCompression: true)
        #expect(after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal)
        #expect(after.metadata.offsetOriginal == before.metadata.offsetOriginal)
        #expect(after.metadata.gpsLatitude == before.metadata.gpsLatitude)
        #expect(after.metadata.gpsLongitude == before.metadata.gpsLongitude)
        #expect(CompressionMetadataTransfer.metadataValuesMatch(key: "ExifIFD:MaxApertureValue",
            [before.embeddedTags["ExifIFD:MaxApertureValue"]!], [after.embeddedTags["ExifIFD:MaxApertureValue"]!]))
        _ = NSApplication.shared
        let avif = try await host.perform(source: developed, format: .avif, quality: 82, preview: true)
        let profile = try tool.execute(["-b", "-ICC_Profile", developed.path]).stdout
        #expect(!profile.isEmpty)
        // This is the RAW path's known sRGB input; ordinary P3 sources still fail closed.
        _ = try CompressionMetadataTransfer.preserve(source: developed, output: avif.url,
            width: avif.width, height: avif.height, profile: profile, originalProfile: true,
            exiftoolURL: toolURL, cancellation: token)
        #expect(try tool.execute(["-b", "-ICC_Profile", avif.url.path]).stdout == profile)
        let avifMetadata = try tool.snapshot(avif.url, strictOffsets: false, forCompression: true)
        #expect(avifMetadata.metadata.offsetOriginal == before.metadata.offsetOriginal)
        #expect(avifMetadata.metadata.gpsLatitude == before.metadata.gpsLatitude)
        try CompressionValidation.verifyOutput(avif.url, width: avif.width, height: avif.height)
        let reference = try CompressionImages.raster(developed, maxPixel: 0, preserveOriginal: true)
        let encoded = try CompressionImages.raster(avif.url, maxPixel: 0, preserveOriginal: true)
        for x in [4, 12, 20, 28] {
            for channel in 0..<3 {
                let index = (8 * 32 + x) * 4 + channel
                #expect(abs(Int(reference.bytes[index]) - Int(encoded.bytes[index])) < 10,
                    "AVIF ICC update must not change RGB colour interpretation")
            }
        }
    }
}
