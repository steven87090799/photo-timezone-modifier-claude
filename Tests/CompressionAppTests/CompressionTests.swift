import AppKit
import Foundation
import ImageIO
import Testing
@testable import PhotoTimezoneApp
@testable import TimezoneCore

@Suite(.serialized)
@MainActor
struct CompressionTests {
    private func toolURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/vendor-exiftool/exiftool")
    }
    private func fixture(in folder: URL, type: String = "public.jpeg", name: String = "source.jpg") throws -> URL {
        let width = 128, height = 96
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x * 2); pixels[i+1] = UInt8(y * 2); pixels[i+2] = UInt8((x+y) % 256)
        }}
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let file = folder.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let tool = ExifTool(url: toolURL())
        let xmp = folder.appendingPathComponent("source.xmp")
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:onone="http://ns.ononesoftware.com/ON1Export/1.0/" xmlns:private="https://example.test/private/" exif:DateTimeOriginal="2026-01-02T03:04:05+08:00" private:OpaqueSettings="keep-this-exact-value" onone:On1ExportData="ZXhwb3J0LW1ldGFkYXRh"/></rdf:RDF></x:xmpmeta>
        """.utf8).write(to: xmp)
        let result = try tool.execute(["-overwrite_original", "-DateTimeOriginal=2026:01:02 03:04:05", "-OffsetTimeOriginal=+08:00",
            "-GPSLatitude=25.033", "-GPSLatitudeRef=N", "-GPSLongitude=121.5654", "-GPSLongitudeRef=E", "-XMP<=\(xmp.path)", file.path])
        #expect(result.status == 0)
        return file
    }

    private func ready(_ host: CompressionHost) async throws {
        _ = NSApplication.shared
        host.loadIfNeeded()
        for _ in 0..<600 {
            if host.isReady { return }
            if let error = host.error { throw NSError(domain: error, code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Compression host did not become ready")
        throw CancellationError()
    }

    @Test func sixFormatsPreserveDatesGPSAndOpaqueXMP() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let original = try Data(contentsOf: source)
        let host = CompressionHost()
        defer { host.shutdown() }
        try await ready(host)
        let tool = ExifTool(url: toolURL())
        let before = try tool.snapshot(source, strictOffsets: false, forCompression: true)
        for format in CompressionFormat.allCases {
            print("Testing compression format: \(format.rawValue)")
            let result = try await host.perform(source: source, format: format, quality: 82, preview: false)
            let after = try tool.snapshot(result.url, strictOffsets: false, forCompression: true)
            #expect(after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal)
            #expect(after.metadata.offsetOriginal == "+08:00")
            #expect(after.metadata.gpsLatitude == before.metadata.gpsLatitude)
            #expect(after.metadata.gpsLongitude == before.metadata.gpsLongitude)
            for (key, value) in before.embeddedTags where key.hasPrefix("XMP") {
                #expect(after.embeddedTags.contains { MetadataVerifier.canonicalCopyKey($0.key) == MetadataVerifier.canonicalCopyKey(key) && $0.value == value }, "\(format): \(key)")
            }
            #expect(!result.metadataStatus.contains("部分中繼資料未保留"), "\(format): \(result.metadataStatus)")
            if format.preservesRGBProfile {
                let a = try tool.execute(["-b", "-ICC_Profile", source.path]).stdout
                if format == .jxl {
                    #expect(!a.isEmpty && CompressionJXL.profileMatches(result.url, expected: a), "\(format) ICC")
                } else {
                    let b = try tool.execute(["-b", "-ICC_Profile", result.url.path]).stdout
                    #expect(!a.isEmpty && a == b, "\(format) ICC")
                }
            }
            #expect(result.bytes > 0)
            #expect(result.width == 128 && result.height == 96)
        }
        #expect(try Data(contentsOf: source) == original)
        host.releaseRuntime()
        #expect(host.webView == nil)
    }

    @Test func highResolutionJXLUsesOneEncoderWithinMemoryBudget() {
        let memory = UInt64(16 * 1024 * 1024 * 1024)
        #expect(CompressionModel.concurrencyLimit(format: .jxl, requested: 4,
            pixelCount: 24_000_000, physicalMemory: memory) == 1)
        #expect(CompressionModel.concurrencyLimit(format: .jpeg, requested: 4,
            pixelCount: 24_000_000, physicalMemory: memory) == 1)
    }

    @Test func nativeJXLRetainsICCThroughMetadataWrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NativeJXLICC-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let output = folder.appendingPathComponent("native.jxl")
        let tool = ExifTool(url: toolURL())
        let sourceICC = try tool.execute(["-b", "-ICC_Profile", source.path]).stdout
        let encoded = try CompressionJXL.encode(source: source, output: output, quality: 82,
                                                preview: false, cancellation: CancellationToken())
        #expect(encoded.originalProfile)
        #expect(!sourceICC.isEmpty && CompressionJXL.profileMatches(output, expected: sourceICC),
                "Native JXL codestream must retain the source profile's color behavior")
        _ = try CompressionMetadataTransfer.preserve(source: source, output: output,
            width: encoded.width, height: encoded.height,
            profile: CompressionImages.colorSpace(source, preserveOriginal: true).copyICCData() as Data?,
            originalProfile: encoded.originalProfile, exiftoolURL: toolURL(),
            iccVerifier: { file, expected in CompressionJXL.profileMatches(file, expected: expected) })
        #expect(CompressionJXL.profileMatches(output, expected: sourceICC),
                "Metadata writing must not change JXL color behavior")
    }

    @Test func nativeJXLQuality100PreservesDecodedPixelsAndAlpha() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NativeJXLExact-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("alpha.png")
        let output = folder.appendingPathComponent("alpha.jxl")
        let pixels: [UInt8] = [0, 0, 0, 0, 100, 20, 5, 128,
                               12, 190, 220, 255, 0, 0, 0, 1]
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = try #require(CGImage(width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let original = try CompressionImages.raster(source, maxPixel: 0, preserveOriginal: true)
        let encoded = try CompressionJXL.encode(source: source, output: output, quality: 100,
                                                preview: false, cancellation: CancellationToken())
        #expect(encoded.originalProfile)
        let decoded = try CompressionImages.raster(output, maxPixel: 0, preserveOriginal: true)
        #expect(decoded.bytes == original.bytes, "Quality 100 must preserve all decoded RGBA samples")
        #expect((0..<original.height * original.width).allSatisfy { index in
            decoded.bytes[index * 4 + 3] == original.bytes[index * 4 + 3]
        }, "JPEG XL must not damage alpha at lossy or lossless qualities")
        let lossyOutput = folder.appendingPathComponent("alpha-lossy.jxl")
        _ = try CompressionJXL.encode(source: source, output: lossyOutput, quality: 82,
                                      preview: false, cancellation: CancellationToken())
        let lossy = try CompressionImages.raster(lossyOutput, maxPixel: 0, preserveOriginal: true)
        #expect((0..<original.height * original.width).allSatisfy { index in
            lossy.bytes[index * 4 + 3] == original.bytes[index * 4 + 3]
        }, "Lossy JPEG XL must preserve the original alpha samples exactly")
    }

    @Test func pngHeifAndTiffInputsCanCompressToJPEG() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionInputs-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = CompressionHost(); defer { host.shutdown() }
        try await ready(host)
        for (type, name) in [("public.png", "source.png"), ("public.heic", "source.heic"), ("public.tiff", "source.tiff")] {
            let file = try fixture(in: folder, type: type, name: name)
            let result = try await host.perform(source: file, format: .jpeg, quality: 82, preview: false)
            #expect(result.bytes > 0)
            if type != "public.tiff" { #expect(throws: PhotoError.self) { _ = try ExifTool(url: toolURL()).snapshot(file) } }
            // TIFF remains a supported timezone-editing input.
            if type == "public.tiff" { _ = try ExifTool(url: toolURL()).snapshot(file) }
        }
    }

    @Test func previewsParallelOutputsExportsAndCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionActions-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let host = CompressionHost(); defer { host.shutdown() }
        try await ready(host)
        for format in CompressionFormat.allCases {
            let preview = try await host.perform(source: source, format: format, quality: 82, preview: true)
            #expect(preview.bytes > 0)
        }
        async let jpeg = host.perform(source: source, format: .jpeg, quality: 82, preview: false)
        async let png = host.perform(source: source, format: .png, quality: 100, preview: false)
        let (a, b) = try await (jpeg, png)
        #expect(try CompressionImages.raster(source, maxPixel: 0, preserveOriginal: true).bytes == CompressionImages.raster(b.url, maxPixel: 0, preserveOriginal: true).bytes)
        let exportFolder = folder.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: false)
        try CompressionExports.saveAll([(a.url, "image.jpg"), (b.url, "image.png"), (a.url, "image.jpg")], in: exportFolder)
        #expect(FileManager.default.fileExists(atPath: exportFolder.appendingPathComponent("image (2).jpg").path))
        let zip = folder.appendingPathComponent("images.zip")
        try CompressionExports.zip([(a.url, "image.jpg"), (b.url, "image.png")], to: zip)
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tq", zip.path]; unzip.standardOutput = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit(); #expect(unzip.terminationStatus == 0)
        let pending = Task { try await host.perform(source: source, format: .jxl, quality: 100, preview: false) }
        await Task.yield(); pending.cancel(); host.cancelAll()
        do { _ = try await pending.value; Issue.record("Cancelled task accepted an output") }
        catch { #expect(error is CancellationError || error.localizedDescription.contains("取消")) }
        host.releaseRuntime()
        #expect(host.webView == nil)
        try await ready(host)
        #expect(try await host.perform(source: source, format: .jxl, quality: 100, preview: false).bytes > 0)
    }

    @Test func selectedFullPreviewShowsActualSizeAndIsReusedByBatch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionFullPreview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let model = CompressionModel()
        defer { model.host.shutdown() }
        model.quality = 82
        model.setActive(true)
        model.addInputs([source])
        for _ in 0..<200 where model.items.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(model.items.count == 1)
        for _ in 0..<500 where model.previewLoading || model.estimate == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.previewIsActual)
        let previewBytes = try #require(model.estimate)
        let directoriesBeforeStart = try FileManager.default.contentsOfDirectory(
            at: model.host.workDirectory, includingPropertiesForKeys: nil)
        #expect(directoriesBeforeStart.count == 1)
        let previewOutput = directoriesBeforeStart[0].appendingPathComponent("output.jpg")
        #expect(FileManager.default.fileExists(atPath: previewOutput.path))

        model.start()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        let result = try #require(model.items.first?.result)
        #expect(result.bytes == previewBytes)
        #expect(result.url.resolvingSymlinksInPath() == previewOutput.resolvingSymlinksInPath())
        #expect(model.items.first?.state == .success)
        model.clear()
        model.setActive(false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_COMPRESSION_JPEG"] != nil))
    func realJPEGKeepsON1AndSource() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_COMPRESSION_JPEG"]))
        let original = try Data(contentsOf: source)
        let host = CompressionHost(); defer { host.shutdown() }
        try await ready(host)
        let result = try await host.perform(source: source, format: .jpeg, quality: 82, preview: false)
        let tool = ExifTool(url: toolURL())
        let before = try tool.snapshot(source, strictOffsets: false, forCompression: true)
        let after = try tool.snapshot(result.url, strictOffsets: false, forCompression: true)
        for (key, value) in before.embeddedTags where key.hasPrefix("XMP") && !key.hasSuffix(":XMPToolkit") {
            #expect(after.embeddedTags.contains { MetadataVerifier.canonicalCopyKey($0.key) == MetadataVerifier.canonicalCopyKey(key) && $0.value == value }, "\(key)")
        }
        #expect(after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal)
        #expect(after.metadata.offsetOriginal == before.metadata.offsetOriginal)
        #expect(try Data(contentsOf: source) == original)
        print("Real JPEG output: \(result.bytes) bytes; \(result.metadataStatus)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_FULL_REAL_COMPRESSION_DIR"] != nil))
    func realPhotosExerciseAllFormatsAndJpegliQualityCurve() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_FULL_REAL_COMPRESSION_DIR"]))
        let jpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_COMPRESSION_JPEG"]))
        let timezoneGPSJPEG = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_GPS_JPEG"]))
        let curveFolder = root.appendingPathComponent("jpegli-quality-curve", isDirectory: true)
        let formatsFolder = root.appendingPathComponent("other-format-output", isDirectory: true)
        try FileManager.default.createDirectory(at: curveFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: formatsFolder, withIntermediateDirectories: true)
        let host = CompressionHost(); defer { host.shutdown() }
        try await ready(host)

        var curve: [[String: Any]] = []
        for quality in [82, 84, 86, 88, 90] {
            let started = Date()
            let result = try await host.perform(source: jpeg, format: .jpeg, quality: quality, preview: false)
            let destination = curveFolder.appendingPathComponent("_DSC9348-jpegli-q\(quality).jpg")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: result.url, to: destination)
            curve.append(["quality": quality, "bytes": result.bytes, "seconds": Date().timeIntervalSince(started), "file": destination.lastPathComponent,
                          "metadataStatus": result.metadataStatus])
        }

        let tool = ExifTool(url: toolURL())
        let before = try tool.snapshot(timezoneGPSJPEG, strictOffsets: false, forCompression: true)
        let reuseFullSizePNG = ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_SKIP_FULL_SIZE_PNG"] == "1"
        var formats: [[String: Any]] = []
        for format in CompressionFormat.allCases {
            if format == .png && reuseFullSizePNG {
                let destination = formatsFolder.appendingPathComponent("_DSC9348-PNG-q82.png")
                #expect(FileManager.default.fileExists(atPath: destination.path), "Previously generated full-size PNG output is required")
                let after = try tool.snapshot(destination, strictOffsets: false, forCompression: true)
                #expect(after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal, "PNG: capture date")
                #expect(after.metadata.offsetOriginal == before.metadata.offsetOriginal, "PNG: timezone offset")
                #expect(after.metadata.gpsLatitude == before.metadata.gpsLatitude, "PNG: GPS latitude")
                #expect(after.metadata.gpsLongitude == before.metadata.gpsLongitude, "PNG: GPS longitude")
                for (key, value) in before.embeddedTags where key.hasPrefix("XMP") && !key.hasSuffix(":XMPToolkit") {
                    #expect(after.embeddedTags.contains {
                        MetadataVerifier.canonicalCopyKey($0.key) == MetadataVerifier.canonicalCopyKey(key) && $0.value == value
                    }, "PNG: \(key)")
                }
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                formats.append(["format": "PNG", "bytes": size, "file": destination.lastPathComponent,
                                "metadataStatus": "已驗證前次全尺寸 PNG 輸出與 GPS／時區／XMP"])
                continue
            }
            let started = Date()
            let result = try await host.perform(source: timezoneGPSJPEG, format: format, quality: 82, preview: false)
            let after = try tool.snapshot(result.url, strictOffsets: false, forCompression: true)
            #expect(after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal, "\(format): capture date")
            #expect(after.metadata.offsetOriginal == before.metadata.offsetOriginal, "\(format): timezone offset")
            #expect(after.metadata.gpsLatitude == before.metadata.gpsLatitude, "\(format): GPS latitude")
            #expect(after.metadata.gpsLongitude == before.metadata.gpsLongitude, "\(format): GPS longitude")
            if [.webp, .avif, .heif, .jxl].contains(format) {
                #expect(result.metadataStatus.contains("IPTC-IIM"), "\(format): missing IPTC must be disclosed")
            } else {
                #expect(!result.metadataStatus.contains("未保留"), "\(format): \(result.metadataStatus)")
            }
            for (key, value) in before.embeddedTags where key.hasPrefix("XMP") && !key.hasSuffix(":XMPToolkit") {
                #expect(after.embeddedTags.contains {
                    MetadataVerifier.canonicalCopyKey($0.key) == MetadataVerifier.canonicalCopyKey(key) && $0.value == value
                }, "\(format): \(key)")
            }
            if format.preservesRGBProfile {
                let sourceICC = try tool.execute(["-b", "-ICC_Profile", timezoneGPSJPEG.path]).stdout
                if format == .jxl {
                    #expect(CompressionJXL.profileMatches(result.url, expected: sourceICC), "\(format): ICC profile")
                } else {
                    let outputICC = try tool.execute(["-b", "-ICC_Profile", result.url.path]).stdout
                    #expect(sourceICC == outputICC, "\(format): ICC profile")
                }
            }
            let destination = formatsFolder.appendingPathComponent("_DSC9348-\(format.rawValue.replacingOccurrences(of: " ", with: ""))-q82.\(format.fileExtension)")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: result.url, to: destination)
            formats.append(["format": format.rawValue, "bytes": result.bytes, "seconds": Date().timeIntervalSince(started), "file": destination.lastPathComponent,
                            "metadataStatus": result.metadataStatus])
        }
        let report: [String: Any] = ["source": "_DSC9348.jpg", "qualityCurve": curve, "realPhotoFormats": formats]
        let reportURL = root.appendingPathComponent("reports/real-photo-compression-results.json")
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        let qualities = curve.compactMap { $0["quality"] as? Int }
        print("Real-photo compression outputs: \(formats.count) formats; Jpegli quality curve: \(qualities)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JXL_BATCH_SOURCE_DIR"] != nil &&
                    ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JXL_BATCH_OUTPUT_DIR"] != nil))
    func realPhotoBatchJXLPreservesTimezoneGPSAndSources() async throws {
        let sourceRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JXL_BATCH_SOURCE_DIR"]))
        let outputRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JXL_BATCH_OUTPUT_DIR"]))
        let values = try FileManager.default.contentsOfDirectory(at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        let sources = values.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        #expect(sources.count == 43, "The real test set must contain all 43 JPEG photos")
        if FileManager.default.fileExists(atPath: outputRoot.path) {
            let existing = try FileManager.default.contentsOfDirectory(atPath: outputRoot.path)
            #expect(existing.isEmpty, "Refusing to overwrite an existing JXL batch folder")
            guard existing.isEmpty else { return }
        } else {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        }
        let reportURL = outputRoot.deletingLastPathComponent().appendingPathComponent("reports/jxl-batch-results.json")
        let tool = ExifTool(url: toolURL())
        let host = CompressionHost(); defer { host.shutdown() }
        var rows: [[String: Any]] = []
        for source in sources {
            let identity = try FileIdentity.read(source)
            let before = try tool.snapshot(source, strictOffsets: false, forCompression: true)
            let started = Date()
            let result = try await host.perform(source: source, format: .jxl, quality: 82, preview: false)
            let after = try tool.snapshot(result.url, strictOffsets: false, forCompression: true)
            let datePreserved = after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal
            let timezonePreserved = after.metadata.offsetOriginal == before.metadata.offsetOriginal &&
                after.metadata.offsetDigitized == before.metadata.offsetDigitized &&
                after.metadata.offsetTime == before.metadata.offsetTime
            let gpsPreserved = after.metadata.gpsLatitude == before.metadata.gpsLatitude &&
                after.metadata.gpsLongitude == before.metadata.gpsLongitude
            #expect(datePreserved, "\(source.lastPathComponent): capture date")
            #expect(timezonePreserved, "\(source.lastPathComponent): timezone offsets")
            #expect(gpsPreserved, "\(source.lastPathComponent): GPS coordinates")
            #expect(!result.metadataStatus.contains("部分中繼資料未保留"),
                    "\(source.lastPathComponent): \(result.metadataStatus)")
            try identity.verify(source)
            let outputName = source.deletingPathExtension().lastPathComponent + ".jxl"
            let destination = outputRoot.appendingPathComponent(outputName)
            try FileManager.default.copyItem(at: result.url, to: destination)
            rows.append(["file": source.lastPathComponent, "outputFile": outputName,
                "sourceBytes": identity.size, "outputBytes": result.bytes,
                "seconds": Date().timeIntervalSince(started),
                "datePreserved": datePreserved, "timezonePreserved": timezonePreserved,
                "gpsPreserved": gpsPreserved, "sourceIdentityUnchanged": true,
                "metadataStatus": result.metadataStatus])
        }
        let report: [String: Any] = ["format": "JPEG XL", "quality": 82,
            "effort": 1, "sourceCount": sources.count, "outputCount": rows.count,
            "allSourceIdentitiesUnchanged": rows.count == sources.count,
            "allDateTimezoneAndGPSChecksPass": rows.allSatisfy {
                ($0["datePreserved"] as? Bool == true) &&
                ($0["timezonePreserved"] as? Bool == true) &&
                ($0["gpsPreserved"] as? Bool == true)
            }, "rows": rows]
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: .atomic)
        print("Real JXL batch: \(rows.count) photos saved to \(outputRoot.path)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JPEGLI_BATCH_SOURCE_DIR"] != nil &&
                    ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JPEGLI_BATCH_OUTPUT_DIR"] != nil))
    func realPhotoBatchJpegliAtDefaultQualityPreservesTimezoneGPSAndSources() async throws {
        let sourceRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JPEGLI_BATCH_SOURCE_DIR"]))
        let outputRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PHOTO_TIMEZONE_REAL_JPEGLI_BATCH_OUTPUT_DIR"]))
        let values = try FileManager.default.contentsOfDirectory(at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        let sources = values.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        #expect(sources.count == 43, "The real test set must contain all 43 JPEG photos")
        if FileManager.default.fileExists(atPath: outputRoot.path) {
            let existing = try FileManager.default.contentsOfDirectory(atPath: outputRoot.path)
            #expect(existing.isEmpty, "Refusing to overwrite an existing Jpegli batch folder")
            guard existing.isEmpty else { return }
        } else {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        }
        let reportURL = outputRoot.deletingLastPathComponent().appendingPathComponent("reports/jpegli-quality86-batch-results.json")
        let tool = ExifTool(url: toolURL())
        let host = CompressionHost(); defer { host.shutdown() }
        var rows: [[String: Any]] = []
        for source in sources {
            let identity = try FileIdentity.read(source)
            let before = try tool.snapshot(source, strictOffsets: false, forCompression: true)
            let sourceICC = try tool.execute(["-b", "-ICC_Profile", source.path]).stdout
            let started = Date()
            let result = try await host.perform(source: source, format: .jpeg, quality: 86, preview: false)
            let after = try tool.snapshot(result.url, strictOffsets: false, forCompression: true)
            let imageSource = try #require(CGImageSourceCreateWithURL(result.url as CFURL, nil))
            let isStandardJPEG = (CGImageSourceGetType(imageSource) as String?) == "public.jpeg"
            let datePreserved = after.metadata.dateTimeOriginal == before.metadata.dateTimeOriginal
            let timezonePreserved = after.metadata.offsetOriginal == before.metadata.offsetOriginal &&
                after.metadata.offsetDigitized == before.metadata.offsetDigitized &&
                after.metadata.offsetTime == before.metadata.offsetTime
            let gpsPreserved = after.metadata.gpsLatitude == before.metadata.gpsLatitude &&
                after.metadata.gpsLongitude == before.metadata.gpsLongitude
            let outputICC = try tool.execute(["-b", "-ICC_Profile", result.url.path]).stdout
            let iccPreserved = sourceICC == outputICC
            #expect(isStandardJPEG, "\(source.lastPathComponent): standard JPEG output")
            #expect(datePreserved, "\(source.lastPathComponent): capture date")
            #expect(timezonePreserved, "\(source.lastPathComponent): timezone offsets")
            #expect(gpsPreserved, "\(source.lastPathComponent): GPS coordinates")
            #expect(iccPreserved, "\(source.lastPathComponent): ICC profile")
            for (key, value) in before.embeddedTags where key.hasPrefix("XMP") && !key.hasSuffix(":XMPToolkit") {
                #expect(after.embeddedTags.contains {
                    MetadataVerifier.canonicalCopyKey($0.key) == MetadataVerifier.canonicalCopyKey(key) && $0.value == value
                }, "\(source.lastPathComponent): \(key)")
            }
            try identity.verify(source)
            let outputName = source.deletingPathExtension().lastPathComponent + ".jpg"
            let destination = outputRoot.appendingPathComponent(outputName)
            try FileManager.default.copyItem(at: result.url, to: destination)
            rows.append(["file": source.lastPathComponent, "outputFile": outputName,
                "sourceBytes": identity.size, "outputBytes": result.bytes,
                "seconds": Date().timeIntervalSince(started),
                "standardJPEG": isStandardJPEG, "datePreserved": datePreserved,
                "timezonePreserved": timezonePreserved, "gpsPreserved": gpsPreserved,
                "iccPreserved": iccPreserved, "sourceIdentityUnchanged": true,
                "metadataStatus": result.metadataStatus])
            try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
        }
        let report: [String: Any] = ["format": "Jpegli JPEG", "quality": 86,
            "sourceCount": sources.count, "outputCount": rows.count,
            "allSourceIdentitiesUnchanged": rows.count == sources.count,
            "allMetadataChecksPass": rows.allSatisfy {
                ($0["standardJPEG"] as? Bool == true) &&
                ($0["datePreserved"] as? Bool == true) &&
                ($0["timezonePreserved"] as? Bool == true) &&
                ($0["gpsPreserved"] as? Bool == true) &&
                ($0["iccPreserved"] as? Bool == true)
            }, "rows": rows]
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: .atomic)
        print("Real Jpegli batch: \(rows.count) photos at quality 86 saved to \(outputRoot.path)")
    }

    @Test func webhookTestUploadAndBatchSummaryUseLoopbackOnlyHTTP() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionWebhook-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("requests.jsonl")
        let serverSource = #"""
import base64, http.server, json, sys
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  row={'path':self.path,'authorization':self.headers.get('Authorization',''),'batch':self.headers.get('X-Nexpress-Batch',''),'contentType':self.headers.get('Content-Type',''),'body':base64.b64encode(body).decode()}
  with open(sys.argv[1],'a') as f: f.write(json.dumps(row)+'\n')
  self.send_response(200); self.send_header('Content-Length','2'); self.end_headers(); self.wfile.write(b'ok')
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", serverSource, log.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var portLine = Data()
        while portLine.last != 0x0A {
            guard let byte = try stdout.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                Issue.record("Local webhook server did not provide a port")
                throw CancellationError()
            }
            portLine.append(byte)
        }
        let portText = String(decoding: portLine.dropLast(), as: UTF8.self)
        let config = try CompressionWebhook.Configuration(url: "http://127.0.0.1:\(portText)/hook", token: "test-token")
        let webhook = CompressionWebhook()
        try await webhook.test(configuration: config)

        let source = try fixture(in: folder)
        let output = folder.appendingPathComponent("compressed.jpg")
        let payload = Data("compressed-test-image".utf8)
        try payload.write(to: output)
        var item = CompressionItem(id: UUID(), source: source, originalBytes: 1024, width: 128, height: 96)
        item.state = .success
        item.format = .jpeg
        item.webhookStatus = "已傳送"
        item.elapsed = 0.25
        item.result = CompressionEngineResult(url: output, bytes: Int64(payload.count), width: 128,
            height: 96, metadataStatus: "metadata verified", frames: 1)
        try await webhook.send(item: item, configuration: config, batchID: "batch-123")
        try await webhook.summary(configuration: config, batchID: "batch-123", items: [item])

        for _ in 0..<100 {
            if let contents = try? String(contentsOf: log, encoding: .utf8),
               contents.split(whereSeparator: \.isNewline).count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let records = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        }
        #expect(records.count == 3)
        #expect(records.allSatisfy { $0["authorization"] == "Bearer test-token" })
        #expect(records.allSatisfy { $0["batch"] == "batch-123" || $0["batch"] == "test" })
        let testPayload = Data(base64Encoded: try #require(records.first?["body"]))!
        #expect(String(decoding: testPayload, as: UTF8.self).contains("\"type\":\"test\""))
        let upload = Data(base64Encoded: try #require(records.dropFirst().first?["body"]))!
        let multipart = String(decoding: upload, as: UTF8.self)
        #expect(multipart.contains("filename=\"\(item.outputName)\""))
        #expect(multipart.contains("compressed-test-image"))
        #expect(multipart.contains("\"timezone\":null"))
        let summary = Data(base64Encoded: try #require(records.last?["body"]))!
        let summaryObject = try #require(JSONSerialization.jsonObject(with: summary) as? [String: Any])
        let totals = try #require(summaryObject["totals"] as? [String: Int])
        #expect(totals["sent"] == 1 && totals["failed"] == 0)
        #expect(throws: (any Error).self) {
            try CompressionWebhook.Configuration(url: "http://example.com/hook", token: "")
        }
        #expect(throws: (any Error).self) {
            try CompressionWebhook.Configuration(url: "http://127.0.0.1:\(portText)/hook", token: "bad\ntoken")
        }
    }

    @Test func localServerStopsListeningAndDeallocates() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionListener-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("test".utf8).write(to: folder.appendingPathComponent("engine.html"))
        var server: CompressionLocalServer? = try CompressionLocalServer(root: folder, preferredPort: 0)
        weak var released = server
        let endpoint = URL(string: "http://127.0.0.1:\(server!.port)/native/health")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: endpoint)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        server?.stop(); server = nil
        for _ in 0..<100 {
            if released == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(released == nil, "The accept loop must not retain an idle server")
        try await Task.sleep(nanoseconds: 50_000_000)
        var request = URLRequest(url: endpoint); request.timeoutInterval = 2
        do { _ = try await session.data(for: request); Issue.record("Stopped listener still accepted a connection") }
        catch { #expect(error is URLError) }
    }

    @Test func engineStartsOnlyWhenCompressionIsOpened() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "nativeCompressionFormat")
        defer {
            if let original { defaults.set(original, forKey: "nativeCompressionFormat") }
            else { defaults.removeObject(forKey: "nativeCompressionFormat") }
        }
        let model = CompressionModel()
        #expect(model.host.webView == nil)
        model.format = .jpeg
        model.setActive(true)
        #expect(model.host.isAvailable(.jpeg))
        #expect(model.host.webView == nil, "Jpegli does not require WebKit")
        model.setActive(false)
        #expect(model.host.webView == nil)
        model.host.shutdown()
    }

    @Test func jpegliPreferenceMigrationPreservesCustomQualityAndUpgradesOldDefault() {
        #expect(CompressionModel.qualityForCurrentJPEGEncoder(savedQuality: nil, encoderVersion: nil) == 86)
        #expect(CompressionModel.qualityForCurrentJPEGEncoder(savedQuality: 82, encoderVersion: nil) == 86)
        #expect(CompressionModel.qualityForCurrentJPEGEncoder(savedQuality: 82, encoderVersion: "mozjpeg") == 86)
        #expect(CompressionModel.qualityForCurrentJPEGEncoder(savedQuality: 82, encoderVersion: "jpegli-v1") == 82)
        #expect(CompressionModel.qualityForCurrentJPEGEncoder(savedQuality: 74, encoderVersion: nil) == 74)
        #expect(CompressionModel.qualityForCurrentJPEGEncoder(savedQuality: 140, encoderVersion: nil) == 100)
    }

    @Test func jpegliQualitiesDecodeAsStandardJPEGWithoutWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JpegliCompatibility-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let host = CompressionHost(); defer { host.shutdown() }
        #expect(!host.isReady && host.webView == nil)
        let tool = ExifTool(url: toolURL())
        let originalICC = try tool.execute(["-b", "-ICC_Profile", source.path]).stdout
        for quality in [1, 49, 82, 95, 100] {
            let result = try await host.perform(source: source, format: .jpeg, quality: quality, preview: false)
            let encoded = try Data(contentsOf: result.url)
            #expect(encoded.prefix(2) == Data([0xff, 0xd8]))
            let imageSource = try #require(CGImageSourceCreateWithURL(result.url as CFURL, nil))
            #expect(CGImageSourceGetType(imageSource) as String? == "public.jpeg")
            let decoded = try CompressionImages.raster(result.url, maxPixel: 0, preserveOriginal: true)
            #expect(decoded.width == 128 && decoded.height == 96)
            #expect(try tool.execute(["-b", "-ICC_Profile", result.url.path]).stdout == originalICC)
            let tags = try tool.execute(["-s", "-EncodingProcess", "-BitsPerSample", "-ColorComponents", "-YCbCrSubSampling", result.url.path]).stdout
            print("Jpegli quality \(quality): \(String(decoding: tags, as: UTF8.self))")
            #expect(host.webView == nil)
        }
        let pending = Task { try await host.perform(source: source, format: .jpeg, quality: 82, preview: false) }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled native JPEG produced a result") }
        catch { #expect(error is CancellationError) }
    }

    @Test func jpegliRejectsInvalidInputAndUsesWhiteForTransparency() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JpegliAlpha-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("transparent.png")
        let output = folder.appendingPathComponent("white.jpg")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(repeating: 0, count: 16 * 16 * 4) as CFData)!
        let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16 * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(throws: PhotoError.self) {
            _ = try CompressionJPEG.encode(source: source, output: output, quality: 0, preview: false, cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let cancelled = CancellationToken(); cancelled.cancel()
        #expect(throws: CancellationError.self) {
            _ = try CompressionJPEG.encode(source: source, output: output, quality: 82, preview: false, cancellation: cancelled)
        }
        _ = try CompressionJPEG.encode(source: source, output: output, quality: 100, preview: false, cancellation: CancellationToken())
        let decoded = try CompressionImages.raster(output, maxPixel: 0, preserveOriginal: true)
        #expect(decoded.bytes.allSatisfy { $0 >= 250 })
    }

    @Test func metadataGroupMatchingDoesNotHideXMPNamespaceChanges() {
        #expect(CompressionMetadataTransfer.comparisonKey("ExifIFD:Make") == CompressionMetadataTransfer.comparisonKey("IFD0:Make"))
        #expect(CompressionMetadataTransfer.comparisonKey("XMP-onone:Copy1:On1ExportData") == "XMP-onone:On1ExportData")
        #expect(CompressionMetadataTransfer.comparisonKey("XMP-iptcCore:Caption") != CompressionMetadataTransfer.comparisonKey("XMP-acdsee:Caption"))
    }

    @Test func metadataComparisonAllowsOnlySubMicroFNumberRounding() {
        #expect(CompressionMetadataTransfer.metadataValuesMatch(key: "ExifIFD:FNumber", ["5.599999905"], ["5.6"]))
        #expect(!CompressionMetadataTransfer.metadataValuesMatch(key: "ExifIFD:FNumber", ["2.8"], ["2.8001"]))
        #expect(!CompressionMetadataTransfer.metadataValuesMatch(key: "XMP-exif:FNumber", ["5.599999905"], ["5.6"]))
        #expect(!CompressionMetadataTransfer.metadataValuesMatch(key: "ExifIFD:FNumber", ["5.6"], []))
    }
}
