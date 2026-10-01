import AppKit
import ImageIO
import SwiftUI
import TimezoneCore

enum AppArtwork {
    static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "photo.badge.clock", accessibilityDescription: nil) ?? NSImage()
    }()
}

/// CGImage is immutable here. Avoid encoding a PNG and decoding it back into
/// NSImage for every selection. Cache <=8 thumbnails and <=8 MiB decoded bytes.
private struct ThumbnailImage: @unchecked Sendable { let image: CGImage }
private actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private var cache: [String: ThumbnailImage] = [:]
    private var recent: [String] = []
    private var costs: [String: Int] = [:]
    private var cost = 0

    func load(_ url: URL) -> ThumbnailImage? {
        guard !Task.isCancelled, let identity = try? FileIdentity.read(url) else { return nil }
        let key = "\(url.path)|\(identity.device):\(identity.inode):\(identity.size):\(identity.modifiedSeconds):\(identity.modifiedNanoseconds):\(identity.changedSeconds):\(identity.changedNanoseconds)"
        if let image = cache[key] {
            recent.removeAll { $0 == key }; recent.append(key)
            return image
        }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    // Never invoke a full RAW decode merely to show the sidebar.
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: url.pathExtension.lowercased() != "arw",
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  !Task.isCancelled, (try? identity.verify(url)) != nil else { return nil }
            let size = image.bytesPerRow * image.height
            guard size <= 8 * 1024 * 1024 else { return nil }
            while !recent.isEmpty && (recent.count >= 8 || cost + size > 8 * 1024 * 1024) {
                let oldest = recent.removeFirst()
                cache.removeValue(forKey: oldest); cost -= costs.removeValue(forKey: oldest) ?? 0
            }
            let result = ThumbnailImage(image: image)
            cache[key] = result; recent.append(key); costs[key] = size; cost += size
            return result
        }
    }
}

@MainActor
private final class ThumbnailState: ObservableObject {
    @Published var image: NSImage?
    @Published var loading = true
}

struct PhotoThumbnail: View {
    let url: URL
    var revision: UUID? = nil
    var allowDecode = true
    private struct Request: Hashable { let url: URL; let revision: UUID?; let allowDecode: Bool }
    @StateObject private var state = ThumbnailState()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
            if let image = state.image {
                Image(nsImage: image).resizable().scaledToFit().padding(4)
            } else if state.loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: Request(url: url, revision: revision, allowDecode: allowDecode)) {
            state.image = nil; state.loading = allowDecode
            guard allowDecode else { return }
            let thumbnail = await ThumbnailLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            state.image = thumbnail.map { NSImage(cgImage: $0.image, size: .zero) }
            state.loading = false
        }
    }
}
