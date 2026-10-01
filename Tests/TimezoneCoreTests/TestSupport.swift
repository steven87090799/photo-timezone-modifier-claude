import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
#endif
import Testing
@testable import TimezoneCore

/// Every fixture and journal belongs to one test; no existing photos are read.
class TemporaryDirectoryTestCase {
    private(set) var temporaryDirectory: URL!

    init() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimezoneCoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        temporaryDirectory = temporaryDirectory.resolvingSymlinksInPath()
    }

    deinit {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func makeFile(_ name: String, contents: Data = Data("discovery fixture".utf8)) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    enum ImageFormat {
        case jpeg, tiff

        #if canImport(CoreGraphics)
        var identifier: CFString {
            (self == .jpeg ? UTType.jpeg.identifier : UTType.tiff.identifier) as CFString
        }
        #endif
    }

    func makePhoto(_ name: String, format: ImageFormat = .jpeg) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(CoreGraphics)
        let context = try requireValue(CGContext(
            data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let image = try requireValue(context.makeImage())
        let destination = try requireValue(CGImageDestinationCreateWithURL(url as CFURL, format.identifier, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoError("Could not encode generated test image at \(url.path)")
        }
        #else
        let jpeg = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAMDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwCjRRRX1p8uf//Z"
        let tiff = "SUkqAAgAAAAKAAABBAABAAAAAwAAAAEBBAABAAAAAgAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAAAgAAABcBBAABAAAAEgAAABwBAwABAAAAAQAAAAAAAAAIAAgACAAzgMwzgMwzgMwzgMwzgMwzgMw="
        try Data(base64Encoded: format == .jpeg ? jpeg : tiff)!.write(to: url)
        #endif
        return url
    }

    func originalBackup(for photo: URL) -> URL {
        URL(fileURLWithPath: photo.path + "_original")
    }

    /// Independent test oracle only. Production never computes photo hashes.
    func digest(of url: URL) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        #else
        return try Data(contentsOf: url).base64EncodedString()
        #endif
    }
}

struct RecordedUpdate {
    let item: PhotoItem
    let completed: Int
    let total: Int
}

struct RecordedJob {
    let events: [JobEvent]

    var discoveries: [[PhotoItem]] {
        events.compactMap { if case .discovered(let items) = $0 { return items }; return nil }
    }

    var updates: [RecordedUpdate] {
        events.compactMap {
            if case .updated(let item, let completed, let total) = $0 {
                return RecordedUpdate(item: item, completed: completed, total: total)
            }
            return nil
        }
    }

    var summaries: [JobSummary] {
        events.compactMap { if case .finished(let summary) = $0 { return summary }; return nil }
    }
}

/// PhotoEngine delivers events from a detached task, not the test's thread.
final class JobEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JobEvent] = []
    private var updateCount = 0
    private let cancelAfterFirstUpdate: CancellationToken?

    init(cancelAfterFirstUpdate: CancellationToken? = nil) {
        self.cancelAfterFirstUpdate = cancelAfterFirstUpdate
    }

    func record(_ event: JobEvent) {
        lock.lock()
        events.append(event)
        var shouldCancel = false
        if case .updated = event {
            updateCount += 1
            shouldCancel = updateCount == 1
        }
        lock.unlock()
        // Synchronous cancellation in the callback precedes the next photo.
        if shouldCancel { cancelAfterFirstUpdate?.cancel() }
    }

    func snapshot() -> RecordedJob {
        lock.lock()
        defer { lock.unlock() }
        return RecordedJob(events: events)
    }
}

// Independent test oracle ONLY. The application never calls ImageDataHash.
extension ExifTool {
    func imageDataSHA256(_ url: URL) throws -> String {
        let result = try execute(["-api", "ImageHashType=SHA256", "-s3", "-ImageDataHash", url.path])
        guard result.status == 0 else { throw PhotoError(result.text) }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#if os(Linux)
@_silgen_name("setxattr") private func linuxTestSet(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ data: UnsafeRawPointer?, _ size: Int, _ flags: Int32) -> Int32
@_silgen_name("getxattr") private func linuxTestGet(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ data: UnsafeMutableRawPointer?, _ size: Int) -> Int
func setxattr(_ path: String, _ name: String, _ data: UnsafeRawPointer?, _ size: Int, _ position: Int, _ flags: Int32) -> Int32 {
    path.withCString { p in ("user." + name).withCString { linuxTestSet(p, $0, data, size, flags) } }
}
func getxattr(_ path: String, _ name: String, _ data: UnsafeMutableRawPointer?, _ size: Int, _ position: Int, _ flags: Int32) -> Int {
    path.withCString { p in ("user." + name).withCString { linuxTestGet(p, $0, data, size) } }
}
#endif
