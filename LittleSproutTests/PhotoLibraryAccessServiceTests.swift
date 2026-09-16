@testable import LittleSprout
import XCTest

/// LS-303 R3（merge-review R2 B1）：`PhotosPickerItem` 本身無法在單元測試建構假值，
/// `identifiers(for:)`（讀 `itemIdentifier`）因此不可測；`partition(identifiers:)` 把「一批
/// `String?` → 保留順序的非 nil 列表＋捨棄筆數」這個純轉換抽出來，用假 identifier 陣列
/// （模擬 picker 沒有帶 `photoLibrary:` 建立、或極罕見讀取失敗時 `itemIdentifier == nil` 的
/// 情況）直接覆蓋。
final class PhotoLibraryAccessServiceTests: XCTestCase {
    func test_partition_allNonNil_keepsOrderAndZeroDropped() {
        let result = PhotoLibraryAccessService.partition(identifiers: ["a", "b", "c"])
        XCTAssertEqual(result.identifiers, ["a", "b", "c"])
        XCTAssertEqual(result.droppedCount, 0)
    }

    func test_partition_allNil_dropsEveryItem() {
        // 這正是 R2 B1 修復前的實際失敗情境——picker 沒有帶 `photoLibrary:` 建立時，每一筆
        // `itemIdentifier` 都是 nil。
        let result = PhotoLibraryAccessService.partition(identifiers: [nil, nil])
        XCTAssertTrue(result.identifiers.isEmpty)
        XCTAssertEqual(result.droppedCount, 2)
    }

    func test_partition_mixedNilAndNonNil_preservesOrderOfSurvivors() {
        let result = PhotoLibraryAccessService.partition(identifiers: ["a", nil, "b", nil, nil])
        XCTAssertEqual(result.identifiers, ["a", "b"])
        XCTAssertEqual(result.droppedCount, 3)
    }

    func test_partition_empty_returnsEmptyAndZeroDropped() {
        let result = PhotoLibraryAccessService.partition(identifiers: [])
        XCTAssertTrue(result.identifiers.isEmpty)
        XCTAssertEqual(result.droppedCount, 0)
    }

    /// merge-review R2 M3 建議補的低成本測試——鎖住 i3「捨棄筆數不再塞假 id」。
    func test_fetchResult_emptyIdentifiers_returnsEmptyPickedAssetsWithDroppedCountPreserved() {
        let result = PhotoLibraryAccessService.fetchResult(for: [], droppedCount: 3)
        XCTAssertTrue(result.pickedAssets.isEmpty)
        XCTAssertTrue(result.assetsByID.isEmpty)
        XCTAssertEqual(result.droppedCount, 3)
    }
}
