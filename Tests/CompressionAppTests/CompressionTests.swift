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
                let b = try tool.execute(["-b", "-ICC_Profile", result.url.path]).stdout
                #expect(!a.isEmpty && a == b, "\(format) ICC")
            }
            #expect(result.bytes > 0)
            #expect(result.width == 128 && result.height == 96)
        }
        #expect(try Data(contentsOf: source) == original)
        host.releaseRuntime()
        #expect(host.webView == nil)
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
}
