@testable import LittleSprout
import XCTest

/// LS-303 R2（merge-review R1 M2，orchestrator 裁決 `c997f234`）：整理頁入口來源決定各群
/// 相簿預設值——從相簿詳情進入預設該相簿（可改），其餘入口（`.timeline`，本票無呼叫點）
/// 維持 C3a「預設不放相簿」。
final class ImportEntrySourceTests: XCTestCase {
    private func group(id: String = "2026-09-10", albumID: UUID? = nil) -> ImportPlan.Group {
        ImportPlan.Group(
            id: id, anchorDate: Date(), isDateUnknown: false, assetLocalIdentifiers: ["a", "b"], albumID: albumID
        )
    }

    func test_defaultAlbumID_albumDetail_returnsThatAlbum() {
        let albumID = UUID()
        XCTAssertEqual(ImportEntrySource.albumDetail(albumID: albumID).defaultAlbumID, albumID)
    }

    func test_defaultAlbumID_timeline_returnsNil() {
        XCTAssertNil(ImportEntrySource.timeline.defaultAlbumID)
    }

    func test_applyDefaultAlbum_albumDetail_setsAlbumIDOnEveryGroup() {
        let albumID = UUID()
        let groups = [group(id: "a"), group(id: "b"), group(id: "c")]
        let result = ImportEntrySource.albumDetail(albumID: albumID).applyDefaultAlbum(to: groups)
        XCTAssertEqual(result.map(\.albumID), [albumID, albumID, albumID])
    }

    func test_applyDefaultAlbum_timeline_leavesGroupsUnchanged() {
        let groups = [group(id: "a", albumID: nil), group(id: "b", albumID: UUID())]
        let result = ImportEntrySource.timeline.applyDefaultAlbum(to: groups)
        XCTAssertEqual(result.map(\.albumID), groups.map(\.albumID), "C3a：不覆寫既有值，維持不放相簿或原值")
    }

    func test_applyDefaultAlbum_preservesOtherFields() {
        let albumID = UUID()
        let original = group(id: "2026-09-10")
        let result = ImportEntrySource.albumDetail(albumID: albumID).applyDefaultAlbum(to: [original])
        XCTAssertEqual(result[0].id, original.id)
        XCTAssertEqual(result[0].assetLocalIdentifiers, original.assetLocalIdentifiers)
        XCTAssertEqual(result[0].anchorDate, original.anchorDate)
    }

    func test_applyDefaultAlbum_emptyGroups_returnsEmpty() {
        XCTAssertTrue(ImportEntrySource.albumDetail(albumID: UUID()).applyDefaultAlbum(to: []).isEmpty)
    }
}
