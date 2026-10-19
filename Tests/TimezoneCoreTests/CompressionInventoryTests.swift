import Foundation
import Testing
@testable import TimezoneCore

struct CompressionInventoryTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func unrecognizedPNGChunkCannotSilentlyDisappear() throws {
        let source = root.appendingPathComponent(".build/vendor-exiftool/t/images/PNG.png")
        let original = try Data(contentsOf: source)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Opaque-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = Data("aaAa".utf8) + Data("irreplaceable private metadata".utf8)
        var crc: UInt32 = 0xffffffff
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        crc ^= 0xffffffff
        func word(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
        let chunk = word(UInt32(payload.count - 4)) + payload + word(crc)
        #expect(original.suffix(8).prefix(4) == Data("IEND".utf8))
        try (original.dropLast(12) + chunk + original.suffix(12)).write(to: file)
        #expect(throws: PhotoError.self) { try CompressionContainerInventory.validate(file) }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func privateJPEGApplicationBlockCannotSilentlyDisappear() throws {
        let source = root.appendingPathComponent(".build/vendor-exiftool/t/images/Sony.jpg")
        let original = try Data(contentsOf: source)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Opaque-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = Data("private archive metadata".utf8)
        let length = payload.count + 2
        let block = Data([0xff, 0xe4, UInt8(length >> 8), UInt8(length & 255)]) + payload
        try (original.prefix(2) + block + original.dropFirst(2)).write(to: file)
        #expect(throws: PhotoError.self) { try CompressionContainerInventory.validate(file) }
        #expect(try Data(contentsOf: source) == original)
    }
}
