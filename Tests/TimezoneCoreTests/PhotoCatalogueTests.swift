import Foundation
import Testing
@testable import TimezoneCore

struct PhotoCatalogueTests {
    private func fixture(_ number: Int, camera: String = "ILCE-7M4", missing: Bool = true,
                         status: PhotoStatus = .ready) -> PhotoItem {
        var item = PhotoItem(url: URL(fileURLWithPath: "/photos/DSC\(number).jpg"), status: status)
        var metadata = PhotoMetadata(dateTimeOriginal: "2025:01:02 03:04:05",
            offsetOriginal: missing ? nil : "+08:00", offsetDigitized: missing ? nil : "+08:00",
            offsetTime: missing ? nil : "+08:00", fileType: "JPEG", createDate: nil, modifyDate: nil, dateTags: [:])
        metadata.cameraModel = camera
        metadata.lensModel = "FE 24-70mm F2.8 GM"
        metadata.fileSize = Int64(number + 1) * 1000
        item.metadata = metadata
        return item
    }

    @Test func testThousandRowsHaveFiveBoundedPagesAndStableNaturalOrdering() {
        let all = PhotoCatalogue.filtered((0..<1000).reversed().map { fixture($0) })
        expectEqual(all.first?.url.lastPathComponent, "DSC0.jpg")
        expectEqual(all.last?.url.lastPathComponent, "DSC999.jpg")
        let pages = (0..<5).map { PhotoCatalogue.page(all, index: $0) }
        expectTrue(pages.allSatisfy { $0.count == 200 })
        expectEqual(Set(pages.flatMap { $0 }.map(\.id)).count, 1000)
        expectEqual(PhotoCatalogue.page(all, index: 100).map(\.id), pages[4].map(\.id))
        expectTrue(PhotoCatalogue.page([], index: -100).isEmpty)
    }

    @Test func testCameraLensDateSearchAndFilterAreCombined() {
        let items = [fixture(0), fixture(1, camera: "Canon R6"), fixture(2, missing: false)]
        let matches = PhotoCatalogue.filtered(items, query: "24-70 2025", filter: .missing, camera: "ILCE-7M4")
        expectEqual(matches.map(\.id), [items[0].id])
        expectEqual(PhotoCatalogue.filtered(items, query: "dsc1").map(\.id), [items[1].id])
        expectEqual(PhotoCatalogue.filtered(items, filter: .complete).map(\.id), [items[2].id])
    }

    @Test func testSelectionCannotExpandBeyondExplicitIDsAndAllPagesCanBeSelected() {
        let items = (0..<1000).map { fixture($0) }
        let ids = Set([items[2].id, items[999].id, UUID()])
        expectEqual(PhotoCatalogue.selected(items, ids: ids).map(\.id), [items[2].id, items[999].id])
        expectEqual(PhotoCatalogue.selected(items, ids: Set(items.map(\.id))).count, 1000)
        expectTrue(PhotoCatalogue.selected(items, ids: []).isEmpty)
    }

    @Test func testRetryFilterExcludesSuccessfulAndSkippedPhotos() {
        let items = [fixture(0, status: .success), fixture(1, status: .failed),
                     fixture(2, status: .cancelled), fixture(3, status: .skipped)]
        expectEqual(PhotoCatalogue.filtered(items, filter: .unfinished).map(\.id), [items[1].id, items[2].id])
        expectEqual(PhotoCatalogue.filtered(items, sort: .size).first?.id, items[3].id)
    }
}
