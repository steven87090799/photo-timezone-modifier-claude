import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

        var identifier: CFString {
            (self == .jpeg ? UTType.jpeg.identifier : UTType.tiff.identifier) as CFString
        }
    }

    func makePhoto(_ name: String, format: ImageFormat = .jpeg) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        return url
    }

    func originalBackup(for photo: URL) -> URL {
        URL(fileURLWithPath: photo.path + "_original")
    }

    /// Independent, whole-file digest for verifying the engine's streaming hash.
    func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
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
