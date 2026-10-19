import AppKit
import Foundation
import ImageIO
import Testing
@testable import PhotoTimezoneApp
@testable import TimezoneCore

@Suite(.serialized)
@MainActor
struct CompressionArchivalTests {
    private var toolURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/vendor-exiftool/exiftool")
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchivalCompression-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func image(in folder: URL, png: Bool = false, alpha: Bool = false, p3: Bool = false) throws -> (URL, Data) {
        let samples: [UInt8] = alpha ? [255, 17, 33, 0, 1, 2, 3, 128, 83, 141, 209, 17, 12, 190, 220, 255] :
            [12, 90, 180, 255, 41, 160, 11, 255, 210, 141, 83, 255, 12, 190, 220, 255]
        let pixels = Data((0..<16).flatMap { _ in samples }) // 8 × 8
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32, space: CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue:
                (alpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let file = folder.appendingPathComponent(png ? "source.png" : "source.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL,
            (png ? "public.png" : "public.jpeg") as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (file, pixels)
    }

    @Test func fullPNGKeepsStraightAlphaAndHiddenRGBAtEveryEffort() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let (source, expected) = try image(in: folder, png: true, alpha: true)
        let original = try Data(contentsOf: source)
        // Read integer samples directly. Comparing two rendered rasters hides
        // the same premultiply/unpremultiply error on both sides.
        #expect(try CompressionImages.raster(source, maxPixel: 0, preserveOriginal: true, preserveDepth: true).bytes == expected)
        let host = CompressionHost(); defer { host.shutdown() }
        for quality in [1, 82, 100] {
            let result = try await host.perform(source: source, format: .png, quality: quality, preview: false)
            let output = try CompressionImages.raster(result.url, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
            #expect(output.bitsPerComponent == 8 && output.width == 8 && output.height == 8)
            #expect(output.bytes == expected, "PNG effort \(quality) changed original integer RGBA samples")
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func SonyJPEGKeepsEntireExifMakerNotesAndThumbnailInJPEGAndHEIF() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = toolURL.deletingLastPathComponent().appendingPathComponent("t/images/Sony.jpg")
        let source = folder.appendingPathComponent("camera.jpg")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let tool = ExifTool(url: toolURL)
        var blocks: [String: Data] = [:]
        for tag in ["EXIF", "MakerNotes", "ThumbnailImage"] {
            blocks[tag] = try tool.execute(["-m", "-b", "-\(tag)", source.path]).stdout
            #expect(blocks[tag]?.isEmpty == false, "\(tag)")
        }
        let host = CompressionHost(); defer { host.shutdown() }
        for format in [CompressionFormat.jpeg, .heif] {
            let result = try await host.perform(source: source, format: format, quality: 86, preview: false)
            for (tag, bytes) in blocks {
                #expect(try tool.execute(["-m", "-b", "-\(tag)", result.url.path]).stdout == bytes, "\(format): \(tag)")
            }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func PNGKeepsOriginalP3CICPChunkAndIntegerPixels() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let (source, samples) = try image(in: folder, png: true, alpha: true, p3: true)
        let original = try Data(contentsOf: source)
        func chunk(_ bytes: Data) throws -> Data {
            let name = try #require(bytes.range(of: Data("cICP".utf8)))
            return bytes.subdata(in: (name.lowerBound - 4)..<(name.upperBound + 8))
        }
        let originalDeclaration = try chunk(original)
        #expect(originalDeclaration.count == 16)
        let host = CompressionHost(); defer { host.shutdown() }
        let result = try await host.perform(source: source, format: .png, quality: 82, preview: false)
        #expect(try chunk(Data(contentsOf: result.url)) == originalDeclaration)
        #expect(try CompressionImages.raster(result.url, maxPixel: 0, preserveOriginal: true, preserveDepth: true).bytes == samples)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func JPEGPrintDensityCannotBeSilentlyReplacedByEncoderDefaults() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let (source, _) = try image(in: folder)
        let tool = ExifTool(url: toolURL)
        #expect(try tool.execute(["-overwrite_original", "-JFIF:ResolutionUnit#=1",
            "-JFIF:XResolution=300", "-JFIF:YResolution=300", source.path]).status == 0)
        let original = try Data(contentsOf: source)
        let host = CompressionHost(); defer { host.shutdown() }
        let result = try await host.perform(source: source, format: .jpeg, quality: 86, preview: false)
        for tag in ["ResolutionUnit", "XResolution", "YResolution"] {
            #expect(try tool.execute(["-b", "-JFIF:\(tag)", source.path]).stdout ==
                tool.execute(["-b", "-JFIF:\(tag)", result.url.path]).stdout)
        }
        do {
            _ = try await host.perform(source: source, format: .heif, quality: 86, preview: false)
            Issue.record("An explicit print density must not disappear into a container without a matching EXIF declaration")
        } catch { #expect(error.localizedDescription.contains("JFIF:"), "\(error)") }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func containersThatCannotPreserveIPTCFailInsteadOfReturningSuccess() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let (source, _) = try image(in: folder)
        let tool = ExifTool(url: toolURL)
        let write = try tool.execute(["-overwrite_original", "-IPTC:Caption-Abstract=Archive forever",
            "-IPTC:Keywords=Family", "-DateTimeOriginal=2026:10:19 12:34:56", "-OffsetTimeOriginal=+05:45", source.path])
        #expect(write.status == 0)
        let original = try Data(contentsOf: source)
        let host = CompressionHost(); defer { host.shutdown() }
        for format in [CompressionFormat.heif, .jxl] {
            do {
                _ = try await host.perform(source: source, format: format, quality: 82, preview: false)
                Issue.record("\(format) accepted an output that cannot preserve IPTC-IIM")
            } catch {
                #expect(error.localizedDescription.contains("IPTC"), "\(format): \(error)")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.workDirectory.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func native16BitPNGKeepsEveryIntegerSample() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sixteen-bit.png")
        let samples: [UInt16] = [65535, 123, 4567, 0, 1, 200, 30000, 32768,
                                 12345, 34567, 54321, 17, 12000, 19000, 22000, 65535]
        let words = (0..<16).flatMap { _ in samples }.map(\.littleEndian)
        let pixels = words.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        #expect(try CompressionImages.raster(source, maxPixel: 0, preserveOriginal: true, preserveDepth: true).bytes == pixels)
        let host = CompressionHost(); defer { host.shutdown() }
        let result = try await host.perform(source: source, format: .png, quality: 82, preview: false)
        let output = try CompressionImages.raster(result.url, maxPixel: 0, preserveOriginal: true, preserveDepth: true)
        #expect(output.bitsPerComponent == 16)
        #expect(output.bytes == pixels)
        #expect(try Data(contentsOf: source) == original)
        #expect(host.webView == nil)
    }

    @Test func PNGTextMustSurviveOrConversionFails() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let (source, _) = try image(in: folder, png: true)
        let tool = ExifTool(url: toolURL)
        #expect(try tool.execute(["-overwrite_original", "-PNG:Title=Family archive", "-PNG:Comment=Keep this original note", source.path]).status == 0)
        let original = try Data(contentsOf: source)
        let host = CompressionHost(); defer { host.shutdown() }
        let result = try await host.perform(source: source, format: .png, quality: 82, preview: false)
        for tag in ["PNG:Title", "PNG:Comment"] {
            let before = try tool.execute(["-b", "-\(tag)", source.path]).stdout
            let after = try tool.execute(["-b", "-\(tag)", result.url.path]).stdout
            #expect(!before.isEmpty && before == after)
        }
        do {
            _ = try await host.perform(source: source, format: .jpeg, quality: 82, preview: false)
            Issue.record("JPEG accepted a conversion that drops PNG text metadata")
        } catch {
            #expect(error.localizedDescription.contains("PNG:") || error.localizedDescription.contains("Comment"))
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func opaqueXMPRemainsByteIdenticalWithoutLayoutEdits() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let (source, _) = try image(in: folder)
        let packet = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="ArchiveOriginal"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:private="https://example.test/private/" private:Orientation="retain-private-value" private:Compression="camera-recipe" private:OpaquePayload="AAECAwQF/w=="/></rdf:RDF></x:xmpmeta>
        """.utf8)
        let xmp = folder.appendingPathComponent("packet.xmp"); try packet.write(to: xmp)
        let tool = ExifTool(url: toolURL)
        #expect(try tool.execute(["-overwrite_original", "-XMP<=\(xmp.path)", source.path]).status == 0)
        let before = try tool.execute(["-b", "-XMP", source.path]).stdout
        let host = CompressionHost(); defer { host.shutdown() }
        let result = try await host.perform(source: source, format: .jpeg, quality: 82, preview: false)
        #expect(try tool.execute(["-b", "-XMP", result.url.path]).stdout == before)
    }

    @Test func PNGColorDeclarationsNeedEquivalentProfileAndIntentForJPEG() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let (source, _) = try image(in: folder, png: true)
        let tool = ExifTool(url: toolURL)
        let host = CompressionHost(); defer { host.shutdown() }
        #expect(String(decoding: try tool.execute(["-s3", "-n", "-PNG:SRGBRendering", source.path]).stdout,
            as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        let converted = try await host.perform(source: source, format: .jpeg, quality: 82, preview: false)
        let expectedProfile = CompressionImages.colorSpace(source, preserveOriginal: true).copyICCData() as Data?
        #expect(try tool.execute(["-b", "-ICC_Profile", converted.url.path]).stdout == expectedProfile)
        #expect(String(decoding: try tool.execute(["-s3", "-n", "-ICC-header:RenderingIntent", converted.url.path]).stdout,
            as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0")

        // A relative/saturation/absolute intent cannot silently become the
        // generated sRGB profile's perceptual intent during conversion.
        #expect(try tool.execute(["-overwrite_original", "-PNG:SRGBRendering#=2", source.path]).status == 0)
        let original = try Data(contentsOf: source)
        do {
            _ = try await host.perform(source: source, format: .jpeg, quality: 82, preview: false)
            Issue.record("A different PNG sRGB rendering intent was discarded")
        } catch {
            #expect(error.localizedDescription.contains("PNG:SRGBRendering"))
        }
        #expect(try Data(contentsOf: source) == original)

        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        let profileFile = folder.appendingPathComponent("source-profile.icc")
        try profile.write(to: profileFile)
        #expect(try tool.execute(["-overwrite_original", "-PNG:SRGBRendering=", "-ICC_Profile<=\(profileFile.path)", source.path]).status == 0)
        let originalICC = try tool.execute(["-b", "-ICC_Profile", source.path]).stdout
        #expect(!originalICC.isEmpty)
        #expect(!(try tool.execute(["-b", "-PNG:ProfileName", source.path]).stdout).isEmpty)
        let wideGamut = try await host.perform(source: source, format: .jpeg, quality: 82, preview: false)
        #expect(try tool.execute(["-b", "-ICC_Profile", wideGamut.url.path]).stdout == originalICC)
    }

    @Test func privateTagsCannotHideBehindCodecFieldNames() {
        for key in ["XMP-private:Orientation", "XMP-private:ImageWidth", "XMP-private:Compression",
                    "XMP-private:ThumbnailImage", "Photoshop:URL", "PNG:Title", "Unknown:OpaquePayload"] {
            #expect(CompressionMetadataTransfer.isPreservedMetadataKey(key, preservePhotoEXIF: false), "\(key)")
        }
        #expect(!CompressionMetadataTransfer.isPreservedMetadataKey("XMP-tiff:Orientation", preservePhotoEXIF: false))
        #expect(CompressionMetadataTransfer.isPreservedMetadataKey("XMP-tiff:Orientation", preservePhotoEXIF: true))
        #expect(!CompressionMetadataTransfer.isPreservedMetadataKey("PNG:ColorType", preservePhotoEXIF: false))
    }

    @Test func xmpWrapperWritabilityIsTheOnlyPermittedPacketByteDifference() {
        let body = Data("<private:recipe>keep everything <?xpacket end='r'?> inside content</private:recipe>".utf8)
        let writable = body + Data("<?xpacket end='w'?>".utf8)
        let readOnly = body + Data("<?xpacket end='r'?>".utf8)
        #expect(CompressionMetadataTransfer.xmpPacketsMatch(writable, readOnly))
        let damaged = Data("<private:recipe>changed</private:recipe><?xpacket end='r'?>".utf8)
        #expect(!CompressionMetadataTransfer.xmpPacketsMatch(writable, damaged))
        #expect(!CompressionMetadataTransfer.xmpPacketsMatch(writable, readOnly + Data(" ".utf8)))
    }
}
