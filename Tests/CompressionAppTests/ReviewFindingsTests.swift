import AppKit
import Darwin
import Foundation
import ImageIO
import JXLBridge
import Testing
@testable import PhotoTimezoneApp
@testable import TimezoneCore

@Suite(.serialized)
@MainActor
struct ReviewFindingsTests {
    @Test func losslessPNGShouldPreserve16BitInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewRGB16-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = (0..<(4096 * 3)).map { UInt16(10000 + $0 % 4096) }
        let data = samples.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 128, height: 32, bitsPerComponent: 16, bitsPerPixel: 48,
            bytesPerRow: 768, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: .byteOrder16Little,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = folder.appendingPathComponent("16-bit-source.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let input = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let inputImage = try #require(CGImageSourceCreateImageAtIndex(input, 0, nil))
        #expect(inputImage.bitsPerComponent == 16)
        _ = NSApplication.shared
        let host = CompressionHost()
        defer { host.shutdown() }
        host.loadIfNeeded()
        for _ in 0..<600 where !host.isReady && host.error == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(host.isReady, "\(host.error ?? "no error")")
        let reference = try CompressionImages.raster(source, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        reference.bytes.withUnsafeBytes { buffer in
            let words = buffer.bindMemory(to: UInt16.self)
            #expect((0..<samples.count).allSatisfy { words[($0 / 3) * 4 + $0 % 3] == samples[$0] }, "16-bit source samples must not be quantized during decode")
        }
        let result = try await host.perform(source: source, format: .png, quality: 100, preview: false)
        let target = folder.appendingPathComponent("lossless-output.png")
        try CompressionExports.saveFile(result.url, to: target)
        let output = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
        let outputImage = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
        print("REVIEW bitdepth: input=\(inputImage.bitsPerComponent), PNG=\(outputImage.bitsPerComponent), status=\(result.metadataStatus)")
        #expect(outputImage.bitsPerComponent == inputImage.bitsPerComponent,
                "A lossless label must preserve source precision, or explicitly warn of conversion")
        let pngPixels = try CompressionImages.raster(target, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        #expect(reference.bytes == pngPixels.bytes, "PNG must preserve decoded integer pixels")
        let jxlResult = try await host.perform(source: source, format: .jxl, quality: 100, preview: false)
        let jxlTarget = folder.appendingPathComponent("lossless-output.jxl")
        try CompressionExports.saveFile(jxlResult.url, to: jxlTarget)
        let jxlSource = try #require(CGImageSourceCreateWithURL(jxlTarget as CFURL, nil))
        let jxlImage = try #require(CGImageSourceCreateImageAtIndex(jxlSource, 0, nil))
        print("REVIEW bitdepth: input=\(inputImage.bitsPerComponent), JXL100=\(jxlImage.bitsPerComponent), status=\(jxlResult.metadataStatus)")
        #expect(jxlImage.bitsPerComponent == inputImage.bitsPerComponent)
        let jxlPixels = try CompressionImages.raster(jxlTarget, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        #expect(reference.bytes == jxlPixels.bytes, "JXL100 must preserve decoded integer pixels")

    }

    @Test func activeServerConnectionsShouldCloseWhenStopped() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewListener-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("test".utf8).write(to: folder.appendingPathComponent("engine.html"))
        var server: CompressionLocalServer? = try CompressionLocalServer(root: folder, preferredPort: 0)
        weak var released = server
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(socket >= 0)
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = server!.port.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)
        try await Task.sleep(nanoseconds: 150_000_000)
        server?.stop(); server = nil
        try await Task.sleep(nanoseconds: 250_000_000)
        print("REVIEW listener: server retained after stop with an incomplete client=\(released != nil)")
        #expect(released == nil, "stop should close accepted clients as well as the listening socket")
        Darwin.shutdown(socket, SHUT_RDWR)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(released == nil, "Closing the test client should allow the server to deallocate")
    }

    @Test nonisolated func inFlightJXLCancellationShouldBeResponsive() throws {
        let width = 4096, height = 4096
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let rgba = bytes.bindMemory(to: UInt8.self)
            var state: UInt32 = 1234567
            for index in stride(from: 0, to: rgba.count, by: 4) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                rgba[index] = UInt8(truncatingIfNeeded: state)
                rgba[index+1] = UInt8(truncatingIfNeeded: state >> 8)
                rgba[index+2] = UInt8(truncatingIfNeeded: state >> 16)
                rgba[index+3] = 255
            }
        }
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { token.cancel() }
        var output: UnsafeMutablePointer<UInt8>?
        var size = 0
        var error = [CChar](repeating: 0, count: 512)
        let started = ProcessInfo.processInfo.systemUptime
        let status = pixels.withUnsafeBytes { rgba in
            pt_jxl_encode_rgba(rgba.bindMemory(to: UInt8.self).baseAddress, rgba.count,
                UInt32(width), UInt32(height), 86, 3, 8, nil, 0, { context in
                    Unmanaged<CancellationToken>.fromOpaque(context!).takeUnretainedValue().isCancelled ? 1 : 0
                }, Unmanaged.passUnretained(token).toOpaque(), &output, &size, &error, error.count)
        }
        defer { pt_jxl_free(output) }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("REVIEW JXL cancellation: requested at 0.15s, returned at \(elapsed)s, status=\(status)")
        #expect(status == 2)
        #expect(elapsed < 2.0, "An in-flight cancellation should be checked while libjxl consumes chunks")
    }
    @Test func pngEffortAndSavingsUseActualValues() {
        #expect(CompressionModel.pngEffort(82) == 4)
        #expect(CompressionModel.pngEffort(95) == 5)
        #expect(CompressionModel.pngEffort(100) == 6)
        #expect(CompressionModel.savings(source: 1000, output: 250) == 0.75)
        #expect(CompressionModel.savings(source: 1000, output: 1500) == -0.5)
        #expect(CompressionModel.savings(source: 0, output: 10) == nil)
        #expect(CompressionModel.savings(source: 100, output: -1) == nil)
    }

    @Test func emptyCompressionPageNeverStartsWebKit() {
        let model = CompressionModel(defaults: UserDefaults(suiteName: "PhotoTimezoneReview-\(UUID())")!)
        defer { model.host.shutdown() }
        model.format = .png; model.setActive(true)
        #expect(model.host.webView == nil)
        model.format = .heif
        #expect(model.host.webView == nil)
        model.setActive(false)
    }

    @Test func idleRuntimeIsReleasedAndCanReload() async throws {
        _ = NSApplication.shared
        let host = CompressionHost(); defer { host.shutdown() }
        host.idleDelayNanoseconds = 200_000_000
        try await host.prepare(.webp)
        #expect(host.webView != nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(host.webView == nil)
        try await host.prepare(.webp)
        #expect(host.webView != nil && host.isReady)
    }

    @Test func comparisonUsesNativePixelsRatherThanSmallPreview() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ComparisonPixels-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let width = 1800, height = 1300
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let value: UInt8 = x % 2 == 0 ? 0 : 255
            pixels[i] = value; pixels[i+1] = value; pixels[i+2] = value
        }}
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = folder.appendingPathComponent("stripes.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        let crop = try #require(CompressionImages.comparisonCrop(url, x: 0, y: 0))
        let cg = try #require(crop.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == 1024 && cg.height == 1024)
        var samples = Data(count: cg.width * cg.height * 4)
        try samples.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        #expect(samples[0] == 0 && samples[4] == 255, "Alternating original pixels must not be resized")
    }

    @Test func transparent16BitIntegerSamplesRemainExact() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Alpha16-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples: [UInt16] = [10001, 45679, 32765, 12345, 12345, 43210, 54321, 23456]
        let data = samples.withUnsafeBytes { Data($0) }
        let image = try #require(CGImage(width: 2, height: 1, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = folder.appendingPathComponent("source.png")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        let decoded = try CompressionImages.raster(source, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        #expect(decoded.bytes == data, "Decoding must not round RGB through premultiplied alpha")
        let host = CompressionHost(); defer { host.shutdown() }
        for format in [CompressionFormat.png, .jxl] {
            let result = try await host.perform(source: source, format: format, quality: 100, preview: false)
            let output = try CompressionImages.raster(result.url, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
            #expect(output.bitsPerComponent == 16)
            #expect(output.bytes == data, "\(format): straight-alpha integer samples must remain exact")
        }
        #expect(host.webView == nil)
    }

    @Test func batchSavingsCompareOnlyTheSameSuccessfulPhotos() {
        let model = CompressionModel(defaults: UserDefaults(suiteName: "PhotoTimezoneReview-\(UUID())")!); defer { model.host.shutdown() }
        let url = URL(fileURLWithPath: "/unused")
        func item(_ original: Int64, _ output: Int64?, _ measured: Int64? = nil) -> CompressionItem {
            var value = CompressionItem(id: UUID(), source: url, originalBytes: original, width: 1, height: 1)
            if let output { value.state = .success; value.result = CompressionEngineResult(url: url, bytes: output,
                sourceBytes: measured, width: 1, height: 1, metadataStatus: "", frames: 1) }
            return value
        }
        model.items = [item(100, 25), item(300, 150), item(9000, nil)]
        #expect(model.completedSourceBytes == 400 && model.resultBytes == 175)
        #expect(model.batchSavings == 0.5625)
        model.items = [item(100, 25, 200)]
        #expect(model.items[0].savings == 0.875)
        #expect(model.completedSourceBytes == 200)
        model.items = []
    }

    @Test func formatsKeepIndependentQualityPreferences() {
        let defaults = UserDefaults(suiteName: "PhotoTimezonePreferences-\(UUID())")!
        let keys = ["nativeCompressionFormat", "nativeCompressionQuality", "nativeCompressionJPEGEncoder",
                    "nativeCompressionQuality.jpg", "nativeCompressionQuality.heic"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let model = CompressionModel(defaults: defaults); defer { model.host.shutdown() }
        #expect(model.format == .jpeg && model.quality == 86)
        model.quality = 91
        model.format = .heif; #expect(model.quality == 70)
        model.quality = 76
        model.format = .jpeg; #expect(model.quality == 91)
        model.format = .heif; #expect(model.quality == 76)
    }

}
