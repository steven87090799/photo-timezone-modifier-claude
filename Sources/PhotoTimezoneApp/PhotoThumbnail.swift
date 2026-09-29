import AppKit
import ImageIO
import SwiftUI

enum AppArtwork {
    static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "photo.badge.clock", accessibilityDescription: nil) ?? NSImage()
    }()
}

/// Serial ImageIO decoding, at most 8 small thumbnails cached, no full-photo
/// grid decode. Cancelled selections never publish a stale thumbnail.
private actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private var cache: [URL: Data] = [:]
    private var recent: [URL] = []

    func load(_ url: URL) -> Data? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[url] { return cached }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceShouldCacheImmediately: false
                  ] as CFDictionary),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  !Task.isCancelled else { return nil }
            cache[url] = data
            recent.append(url)
            if recent.count > 8 { cache.removeValue(forKey: recent.removeFirst()) }
            return data
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
    @StateObject private var state = ThumbnailState()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
            if let image = state.image {
                Image(nsImage: image).resizable().scaledToFit().padding(4)
            } else if state.loading {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo")
                    Text("無縮圖可預覽").font(.caption2)
                }.foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("所選相片的唯讀縮圖")
        .task(id: url) {
            state.image = nil; state.loading = true
            let data = await ThumbnailLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            state.image = data.flatMap(NSImage.init(data:))
            state.loading = false
        }
    }
}
