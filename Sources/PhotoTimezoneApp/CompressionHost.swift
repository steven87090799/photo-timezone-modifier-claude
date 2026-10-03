import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import WebKit

private enum CompressionHostError: LocalizedError {
    case missingAssets
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .missingAssets: return "找不到 App 內建的壓縮頁資產。"
        case .socket(let detail): return "無法啟動本機壓縮頁：\(detail)"
        }
    }
}

/// A loopback-only origin lets WebKit run module workers and WASM from bundled files.
/// Image bytes sent to the native endpoints never leave this Mac.
private final class CompressionLocalServer {
    let port: UInt16
    private let listener: Int32
    private let root: URL
    private let imageQueue = DispatchQueue(label: "tw.steven.phototimezone.compression.image")
    private let maxBodyBytes = 256 * 1024 * 1024

    init(root: URL, preferredPort: UInt16) throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
            throw CompressionHostError.missingAssets
        }
        self.root = root.resolvingSymlinksInPath()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CompressionHostError.socket(String(cString: strerror(errno))) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = preferredPort.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let preferredResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if preferredResult != 0 {
            address.sin_port = 0
            let fallbackResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard fallbackResult == 0 else {
                let detail = String(cString: strerror(errno))
                Darwin.close(fd)
                throw CompressionHostError.socket(detail)
            }
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(fd)
            throw CompressionHostError.socket(detail)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard gotName == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(fd)
            throw CompressionHostError.socket(detail)
        }
        listener = fd
        port = UInt16(bigEndian: bound.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptConnections() }
    }

    deinit { Darwin.close(listener) }

    private func acceptConnections() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { return }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                autoreleasepool {
                    var noSignal: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    var timeout = timeval(tv_sec: 40, tv_usec: 0)
                    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    serve(client)
                    Darwin.close(client)
                }
            }
        }
    }

    private func serve(_ client: Int32) {
        let separator = Data("\r\n\r\n".utf8)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while received.range(of: separator) == nil {
            let count = chunk.withUnsafeMutableBytes { Darwin.recv(client, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return }
            received.append(contentsOf: chunk.prefix(count))
            if received.count > 65_536 {
                respond(client, status: 431, type: "text/plain", body: Data("Header too large".utf8))
                return
            }
        }
        guard let range = received.range(of: separator),
              let header = String(data: received[..<range.lowerBound], encoding: .utf8) else {
            respond(client, status: 400, type: "text/plain", body: Data("Bad request".utf8))
            return
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3 else {
            respond(client, status: 400, type: "text/plain", body: Data("Bad request".utf8))
            return
        }
        let method = String(request[0])
        let target = String(request[1])
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let origin = "http://127.0.0.1:\(port)"
        guard headers["host"] == "127.0.0.1:\(port)",
              method != "POST" || headers["origin"] == nil || headers["origin"] == origin else {
            respond(client, status: 403, type: "text/plain", body: Data("Forbidden".utf8))
            return
        }
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if method == "GET" || method == "HEAD" {
            if path == "/native/health" {
                let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.heic") == true
                let body = Data("{\"heif\":\(supported)}".utf8)
                respond(client, status: 200, type: "application/json", body: method == "HEAD" ? Data() : body)
                return
            }
            serveAsset(client, path: path, headOnly: method == "HEAD")
            return
        }
        guard method == "POST",
              path == "/native/heif/encode" || path == "/native/heif/decode",
              let lengthText = headers["content-length"], let bodyLength = Int(lengthText),
              bodyLength > 0, bodyLength <= maxBodyBytes else {
            respond(client, status: 400, type: "text/plain", body: Data("Unsupported request".utf8))
            return
        }
        var body = Data(received[range.upperBound...])
        guard body.count <= bodyLength else {
            respond(client, status: 400, type: "text/plain", body: Data("Unexpected body length".utf8))
            return
        }
        while body.count < bodyLength {
            let count = chunk.withUnsafeMutableBytes {
                Darwin.recv(client, $0.baseAddress, min($0.count, bodyLength - body.count), 0)
            }
            guard count > 0 else { return }
            body.append(contentsOf: chunk.prefix(count))
        }
        let output: Data? = imageQueue.sync {
            path.hasSuffix("/encode") ? encodeHEIC(body, headers: headers) : decodeHEIC(body, headers: headers)
        }
        guard let output else {
            respond(client, status: 422, type: "text/plain", body: Data("ImageIO 無法處理此影像。".utf8))
            return
        }
        respond(client, status: 200, type: path.hasSuffix("/encode") ? "image/heic" : "image/png", body: output)
    }

    private func serveAsset(_ client: Int32, path: String, headOnly: Bool) {
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/"),
              !decoded.contains("\\"), !decoded.split(separator: "/").contains("..") else {
            respond(client, status: 403, type: "text/plain", body: Data("Forbidden".utf8))
            return
        }
        let relative = decoded == "/" ? "index.html" : String(decoded.dropFirst())
        let file = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            respond(client, status: 404, type: "text/plain", body: Data("Not found".utf8))
            return
        }
        let type: String
        switch file.pathExtension.lowercased() {
        case "html": type = "text/html; charset=utf-8"
        case "js", "mjs": type = "text/javascript; charset=utf-8"
        case "json", "webmanifest": type = "application/json"
        case "wasm": type = "application/wasm"
        case "woff2": type = "font/woff2"
        case "png": type = "image/png"
        case "svg": type = "image/svg+xml"
        default: type = "application/octet-stream"
        }
        respond(client, status: 200, type: type, body: headOnly ? Data() : data)
    }

    private func respond(_ client: Int32, status: Int, type: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 422: reason = "Unprocessable Content"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        sendAll(client, Data(header.utf8))
        sendAll(client, body)
    }

    private func sendAll(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(client, base.advanced(by: sent), bytes.count - sent, 0)
                if count <= 0 { return }
                sent += count
            }
        }
    }

    private func encodeHEIC(_ rgba: Data, headers: [String: String]) -> Data? {
        guard let width = Int(headers["x-image-width"] ?? ""),
              let height = Int(headers["x-image-height"] ?? ""),
              let quality = Int(headers["x-image-quality"] ?? ""),
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              (1...100).contains(quality),
              width <= maxBodyBytes / 4 / height,
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big)
        guard let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space, bitmapInfo: bitmap,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func decodeHEIC(_ input: Data, headers: [String: String]) -> Data? {
        guard let source = CGImageSourceCreateWithData(input as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let requested = Int(headers["x-max-width"] ?? "") ?? 0
        let maxPixel = requested > 0 ? min(requested, 4096) : max(width, height)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

final class CompressionHost: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var error: String?
    let webView: WKWebView
    private var server: CompressionLocalServer?
    private var loaded = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        do {
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("CompressionWeb")
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CompressionWeb")
            let root = bundled.flatMap {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) ? $0 : nil
            } ?? source
            let saved = UserDefaults.standard.integer(forKey: "compressionLocalPort")
            let preferred = saved > 0 && saved <= UInt16.max ? UInt16(saved) : UInt16.random(in: 40_000...60_000)
            let server = try CompressionLocalServer(root: root, preferredPort: preferred)
            UserDefaults.standard.set(Int(server.port), forKey: "compressionLocalPort")
            self.server = server
            let url = URL(string: "http://127.0.0.1:\(server.port)/")!
            webView.load(URLRequest(url: url))
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload {
            decisionHandler(.download)
        } else if let url = action.request.url, url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else if action.targetFrame == nil, let url = action.request.url,
                  url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else if let url = action.request.url, let server,
                  url.scheme == "http", url.host == "127.0.0.1",
                  url.port == Int(server.port) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { result in completionHandler(result == .OK ? panel.url : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
}

private struct CompressionWebView: NSViewRepresentable {
    let host: CompressionHost
    func makeNSView(context: Context) -> WKWebView { host.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct CompressionView: View {
    @ObservedObject var host: CompressionHost

    var body: some View {
        Group {
            if let error = host.error {
                ContentUnavailableView("無法開啟壓縮頁", systemImage: "photo.on.rectangle.angled", description: Text(error))
            } else {
                CompressionWebView(host: host)
            }
        }
        .onAppear { host.loadIfNeeded() }
    }
}
