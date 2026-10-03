import Foundation
import Testing
@testable import TimezoneCore

@Suite(.serialized)
final class FileDiscoveryTests: TemporaryDirectoryTestCase {
    @Test func testReviewCopyDestinationTerminatesAtFilesystemRoot() throws {
        let photo = try makeFile("source/photo.jpg")
        let output = try makeDirectory("destination")
        let individual = try DestinationPlan(destination: output, roots: [photo])
        #expect(try individual.output(for: photo).path == output.appendingPathComponent("photo.jpg").path)
        let root = photo.deletingLastPathComponent()
        let directory = try DestinationPlan(destination: output, roots: [root])
        #expect(try directory.output(for: photo).path == output.appendingPathComponent("source/photo.jpg").path)
    }

    @Test func testFilesystemRootIsRejectedWithoutEnumerationOrMapping() throws {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let items = FileDiscovery.collect(inputs: [root], recursive: true, cancellation: CancellationToken())
        expectEqual(items.count, 1)
        expectEqual(items.first?.status, .failed)
        expectTrue(items.first?.detail.contains("根目錄") == true)

        let output = try makeDirectory("root-output")
        #expect(throws: PhotoError.self) {
            try CopyDestination.validate(output, roots: [root])
        }
    }

    @Test func testSidecarIndexHandlesMixedCaseExtensionsAndRefreshesDirectoryChanges() throws {
        let photo = try makeFile("mixed/photo.jpg")
        let xmp = try makeFile("mixed/photo.XmP", contents: Data("xmp".utf8))
        let index = SidecarIndex(capacity: 2)

        var found = try SidecarSupport.find(beside: photo, index: index)
        expectEqual(Set(found.map(\.lastPathComponent)), Set(["photo.XmP"]))

        let on1 = try makeFile("mixed/photo.jpg.On1", contents: Data("on1".utf8))
        let acr = try makeFile("mixed/photo.aCr", contents: Data("acr".utf8))
        found = try SidecarSupport.find(beside: photo, index: index)
        expectEqual(Set(found.map(\.lastPathComponent)), Set(["photo.XmP", "photo.jpg.On1", "photo.aCr"]))

        try FileManager.default.removeItem(at: xmp)
        found = try SidecarSupport.find(beside: photo, index: index)
        expectEqual(Set(found.map(\.lastPathComponent)), Set([on1.lastPathComponent, acr.lastPathComponent]))
    }

    @Test func testPR3ReviewSidecarIndexRejectsMatchingNonregularEntries() throws {
        let photo = try makeFile("invalid/photo.jpg")
        let target = try makeFile("external.xmp")
        let linked = photo.deletingPathExtension().appendingPathExtension("XmP")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        let index = SidecarIndex()
        #expect(throws: PhotoError.self) { try index.find(beside: photo) }
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked,
            withDestinationURL: temporaryDirectory.appendingPathComponent("missing.xmp"))
        #expect(throws: PhotoError.self) { try index.find(beside: photo) }
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        #expect(throws: PhotoError.self) { try index.find(beside: photo) }
        // An unrelated broken companion must not block other photos.
        let other = try makeFile("invalid/other.jpg")
        #expect(try index.find(beside: other).isEmpty)
    }

    @Test func testPR3ReviewSidecarBasenameMatchingIsCaseInsensitive() throws {
        let photo = try makeFile("case/PHOTO.jpg")
        let sidecar = try makeFile("case/photo.XmP")
        let fullNameSidecar = try makeFile("case/photo.JPG.oN1")
        let index = SidecarIndex()
        #expect(Set(try index.find(beside: photo).map(\.path)) == Set([sidecar.path, fullNameSidecar.path]))
    }

    @Test func testReviewSidecarSetChangesRequireRescan() throws {
        let photo = try makeFile("review.jpg")
        let original = try SidecarSupport.find(beside: photo)
        try SidecarSupport.verifyUnchanged(original, beside: photo)
        let sidecar = try makeFile("review.xmp")
        #expect(throws: PhotoError.self) { try SidecarSupport.verifyUnchanged(original, beside: photo) }
        let rescanned = try SidecarSupport.find(beside: photo)
        try SidecarSupport.verifyUnchanged(rescanned, beside: photo)
        try FileManager.default.removeItem(at: sidecar)
        #expect(throws: PhotoError.self) { try SidecarSupport.verifyUnchanged(rescanned, beside: photo) }
    }

    @Test func testNonrecursiveDiscoveryIncludesOnlySupportedVisibleTopLevelFiles() throws {
        let root = try makeDirectory("photos")
        let expected = try ["one.jpg", "two.JPEG", "three.tif", "four.TIFF", "five.ARW"]
            .map { try makeFile("photos/\($0)") }
        try makeFile("photos/nested/child.jpg")
        try makeFile("photos/.hidden.jpg")
        try makeFile("photos/.hidden-folder/child.jpg")
        try makeFile("photos/readme.txt")
        try makeFile("photos/one.jpg_original")
        try makeFile("photos/one.jpg.before-restore-123.backup")

        let items = collect([root], recursive: false)
        expectEqual(Set(items.map(\.url)), Set(expected))
        expectEqual(items.count, expected.count)
        expectTrue(items.allSatisfy { $0.status == .pending })
    }

    @Test func testRecursiveDiscoveryIncludesNestedFilesButNotHiddenFilesOrBackups() throws {
        let root = try makeDirectory("photos")
        let expected = try ["top.jpg", "one/child.TIFF", "one/two/deep.arw"]
            .map { try makeFile("photos/\($0)") }
        try makeFile("photos/one/.hidden.jpeg")
        try makeFile("photos/.private/secret.jpg")
        try makeFile("photos/one/child.TIFF_original")
        try makeFile("photos/one/child.TIFF.before-restore-123.backup")
        try makeFile("photos/one/readme.md")

        let items = collect([root], recursive: true)
        expectEqual(Set(items.map(\.url)), Set(expected))
        expectEqual(items.count, expected.count)
        expectTrue(items.allSatisfy { $0.status == .pending })
    }

    @Test func testOverlappingDirectoriesRepeatedFilesAndStandardizedPathsAreDeduplicated() throws {
        let root = try makeDirectory("photos")
        let nested = try makeDirectory("photos/nested")
        let first = try makeFile("photos/first.jpg")
        let second = try makeFile("photos/nested/second.tif")
        let alternate = URL(fileURLWithPath: root.path + "/nested/../first.jpg")

        let items = collect([first, alternate, root, nested, second, root, first], recursive: true)
        expectEqual(items.count, 2)
        expectEqual(Set(items.map(\.url)), Set([first, second]))
        expectEqual(Set(items.map(\.id)).count, 2)
    }

    @Test func testEnumerationExcludesFileLinksDirectoryLinksAndSymlinkCycles() throws {
        let root = try makeDirectory("photos")
        let photo = try makeFile("photos/real.jpg")
        let external = try makeDirectory("external")
        try makeFile("external/not-in-input.tiff")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.jpg"), withDestinationURL: photo)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)

        let items = collect([root], recursive: true)
        expectEqual(items.map(\.url), [photo])
        expectEqual(items.map(\.status), [.pending])
    }

    @Test func testExplicitSymlinksAreReportedAsSkippedAndNeverResolvedIntoPhotos() throws {
        let photo = try makeFile("real.jpg")
        let directory = try makeDirectory("external")
        try makeFile("external/other.jpg")
        let fileLink = temporaryDirectory.appendingPathComponent("alias.jpg")
        let directoryLink = temporaryDirectory.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: photo)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)

        let items = collect([fileLink, directoryLink, photo], recursive: true)
        expectEqual(items.map(\.url.path), [fileLink, directoryLink, photo].map(\.path))
        expectEqual(items.map(\.status), [.skipped, .skipped, .pending])
        expectTrue(items.prefix(2).allSatisfy { !$0.detail.isEmpty })
    }

    @Test func testExplicitUnsupportedAndMissingFilesHaveDistinctDiscoveryOutcomes() throws {
        let unsupported = try makeFile("notes.txt")
        let missing = temporaryDirectory.appendingPathComponent("missing.jpg")
        let items = collect([unsupported, missing], recursive: false)
        expectEqual(items.map(\.url), [unsupported, missing])
        expectEqual(items.map(\.status), [.skipped, .failed])
        expectTrue(items.allSatisfy { !$0.detail.isEmpty })
    }

    @Test func testAlreadyCancelledDiscoveryDoesNotVisitAnyInputOrEmitProgress() throws {
        let root = try makeDirectory("photos")
        try makeFile("photos/first.jpg")
        let cancellation = CancellationToken()
        cancellation.cancel()
        cancellation.cancel()
        var phaseCount = 0
        let items = FileDiscovery.collect(inputs: [root], recursive: true, cancellation: cancellation) { _ in
            phaseCount += 1
        }
        expectTrue(cancellation.isCancelled)
        expectTrue(items.isEmpty)
        expectEqual(phaseCount, 0)
    }

    @Test func testCancellationFromDiscoveryProgressStopsEnumerationAndLaterInputs() throws {
        let root = try makeDirectory("photos")
        for index in 0..<450 { try makeFile("photos/\(index).jpg") }
        let laterInput = try makeFile("later.jpg")
        let cancellation = CancellationToken()
        var phases: [String] = []

        let items = FileDiscovery.collect(inputs: [root, laterInput], recursive: true, cancellation: cancellation) {
            phases.append($0)
            cancellation.cancel()
        }

        expectTrue(cancellation.isCancelled)
        expectEqual(phases.count, 1)
        expectFalse(phases.first?.isEmpty ?? true)
        expectEqual(items.count, 200, "Cancellation at the first 200-entry progress event must stop promptly")
        expectEqual(Set(items.map(\.url)).count, items.count)
        expectFalse(items.contains { $0.url == laterInput })
        expectTrue(items.allSatisfy { $0.status == .pending })
    }

    @Test func testEmptyDirectoryProducesNoItems() throws {
        let root = try makeDirectory("empty")
        expectTrue(collect([root], recursive: false).isEmpty)
        expectTrue(collect([root], recursive: true).isEmpty)
        expectTrue(collect([], recursive: true).isEmpty)
    }

    private func collect(_ inputs: [URL], recursive: Bool) -> [PhotoItem] {
        FileDiscovery.collect(inputs: inputs, recursive: recursive, cancellation: CancellationToken())
    }
}
