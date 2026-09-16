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
        XCTAssertEqual(ImportEntrySource.albumDetail(albumID: albumID, albumName: "測試相簿").defaultAlbumID, albumID)
    }

    func test_defaultAlbumID_timeline_returnsNil() {
        XCTAssertNil(ImportEntrySource.timeline.defaultAlbumID)
    }

    /// i2（LS-303 R5，merge-review R4 `902eb329`）：`ImportGroupCardView.albumLabel` 的
    /// fallback 顯示名稱來源。
    func test_defaultAlbumName_albumDetail_returnsThatName() {
        XCTAssertEqual(
            ImportEntrySource.albumDetail(albumID: UUID(), albumName: "生日派對").defaultAlbumName, "生日派對"
        )
    }

    func test_defaultAlbumName_timeline_returnsNil() {
        XCTAssertNil(ImportEntrySource.timeline.defaultAlbumName)
    }

    func test_applyDefaultAlbum_albumDetail_setsAlbumIDOnEveryGroup() {
        let albumID = UUID()
        let groups = [group(id: "a"), group(id: "b"), group(id: "c")]
        let result = ImportEntrySource.albumDetail(albumID: albumID, albumName: "測試相簿").applyDefaultAlbum(to: groups)
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
        let result = ImportEntrySource.albumDetail(albumID: albumID, albumName: "測試相簿")
            .applyDefaultAlbum(to: [original])
        XCTAssertEqual(result[0].id, original.id)
        XCTAssertEqual(result[0].assetLocalIdentifiers, original.assetLocalIdentifiers)
        XCTAssertEqual(result[0].anchorDate, original.anchorDate)
    }

    func test_applyDefaultAlbum_emptyGroups_returnsEmpty() {
        let source = ImportEntrySource.albumDetail(albumID: UUID(), albumName: "測試相簿")
        XCTAssertTrue(source.applyDefaultAlbum(to: []).isEmpty)
    }

    // MARK: - `ImportPlan.hasUnskippedGroupsWithoutAlbum`（LS-303 R3，merge-review R2 M2）

    private func plan(_ groups: [ImportPlan.Group]) -> ImportPlan {
        ImportPlan(groups: groups)
    }

    func test_hasUnskippedGroupsWithoutAlbum_allGroupsHaveAlbum_returnsFalse() {
        let albumID = UUID()
        let plan = plan([group(id: "a", albumID: albumID), group(id: "b", albumID: albumID)])
        XCTAssertFalse(plan.hasUnskippedGroupsWithoutAlbum)
    }

    func test_hasUnskippedGroupsWithoutAlbum_oneUnskippedGroupMissingAlbum_returnsTrue() {
        let plan = plan([group(id: "a", albumID: UUID()), group(id: "b", albumID: nil)])
        XCTAssertTrue(plan.hasUnskippedGroupsWithoutAlbum)
    }

    func test_hasUnskippedGroupsWithoutAlbum_skippedGroupMissingAlbum_returnsFalse() {
        var skipped = group(id: "b", albumID: nil)
        skipped.isSkipped = true
        XCTAssertFalse(
            plan([group(id: "a", albumID: UUID()), skipped]).hasUnskippedGroupsWithoutAlbum,
            "略過的群即使沒有相簿也不擋主鈕——它本來就不會被匯入"
        )
    }

    func test_hasUnskippedGroupsWithoutAlbum_emptyGroupMissingAlbum_returnsFalse() {
        let empty = ImportPlan.Group(id: "empty", anchorDate: Date(), isDateUnknown: false, assetLocalIdentifiers: [])
        XCTAssertFalse(
            plan([empty]).hasUnskippedGroupsWithoutAlbum, "沒有任何資產的群不會實際造成任何照片沒地方放"
        )
    }
}
