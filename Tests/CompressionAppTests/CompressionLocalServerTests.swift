import Foundation
import Testing
@testable import PhotoTimezoneApp
@testable import TimezoneCore

struct CompressionLocalServerTests {
    @Test func imageRoutesValidateSessionAndJobBeforeReadingBody() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("test".utf8).write(to: folder.appendingPathComponent("engine.html"))
        let server = try CompressionLocalServer(root: folder, preferredPort: 0)
        defer { server.stop() }
        let id = UUID().uuidString
        let cancellation = CancellationToken()
        server.register(id: id, source: folder.appendingPathComponent("source.png"),
                        output: folder.appendingPathComponent("output.png"), format: .png,
                        preview: false, cancellation: cancellation)

        func route(_ method: String, _ path: String, credential: String? = nil,
                   origin: String? = nil, length: Int? = nil) throws -> CompressionLocalServer.Route {
            var lines = ["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:\(server.port)"]
            if let credential { lines.append("X-PhotoTimezone-Session: \(credential)") }
            if let origin { lines.append("Origin: \(origin)") }
            if let length { lines += ["Content-Type: application/octet-stream", "Content-Length: \(length)"] }
            let request = try #require(CompressionLocalServer.Request(Data(lines.joined(separator: "\r\n").utf8)))
            return try server.authorize(request)
        }

        #expect(try route("GET", "/engine.html") == .asset(path: "/engine.html", headOnly: false))
        #expect(try route("GET", "/native/raster/\(id)", credential: server.credential) == .raster(id: id))
        #expect(try route("POST", "/native/result/\(id)", credential: server.credential,
                          origin: server.origin, length: 32) == .result(id: id, length: 32))
        #expect(throws: CompressionLocalServer.Rejection.forbidden) {
            try route("POST", "/native/result/\(id)", origin: server.origin, length: 32)
        }
        #expect(throws: CompressionLocalServer.Rejection.forbidden) {
            try route("POST", "/native/result/\(id)", credential: server.credential, length: 32)
        }
        #expect(throws: CompressionLocalServer.Rejection.notFound) {
            try route("POST", "/native/result/\(UUID().uuidString)", credential: server.credential,
                      origin: server.origin, length: 32)
        }
        #expect(throws: CompressionLocalServer.Rejection.tooLarge) {
            try route("POST", "/native/result/\(id)", credential: server.credential,
                      origin: server.origin, length: CompressionLocalServer.maxUploadBytes + 1)
        }
        #expect(throws: CompressionLocalServer.Rejection.notFound) {
            try route("GET", "/vendor/webp_dec.wasm")
        }
        cancellation.cancel()
        #expect(throws: CompressionLocalServer.Rejection.notFound) {
            try route("GET", "/native/raster/\(id)", credential: server.credential)
        }
    }

    @Test func connectionAndUploadBudgetsRecoverAfterUse() {
        var budget = CompressionLocalServer.Budget(connectionLimit: 2, uploadLimit: 12)
        let admissions = (0..<3).map { _ in budget.admitConnection() }
        #expect(admissions == [true, true, false])
        budget.closeConnection()
        let reopened = budget.admitConnection()
        #expect(reopened)

        let reservations = [8, 5, 4].map { budget.reserveUpload($0) }
        #expect(reservations == [true, false, true])
        budget.releaseUpload(8)
        let reused = budget.reserveUpload(8)
        #expect(reused)
        budget.releaseUpload(12)
        #expect(budget.uploadBytes == 0)
    }
}
