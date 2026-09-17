import Foundation
@testable import LittleSprout
import XCTest

/// LS-304：`ImportBatchSession` 純狀態累積邏輯——`append`／`markGroupResolved`／
/// `isFullyEnqueued` 是 `Import04ProgressView`／`Import05SummaryView` 判斷「這個批次目前
/// 進度如何」的唯一資料來源，見該型別文件註解。
@MainActor
final class ImportBatchSessionTests: XCTestCase {
    func test_initialState_noEntriesAndNotFullyEnqueued() {
        let session = ImportBatchSession(expectedAssetCount: 5, nonSkippedGroupCount: 2)

        XCTAssertTrue(session.entryIDs.isEmpty)
        XCTAssertFalse(session.isFullyEnqueued, "還沒有任何群回報 resolved 之前不該視為已完全入列")
    }

    func test_append_accumulatesEntryIDsInOrder() {
        let session = ImportBatchSession(expectedAssetCount: 2, nonSkippedGroupCount: 1)
        let first = UUID()
        let second = UUID()

        session.append(first)
        session.append(second)

        XCTAssertEqual(session.entryIDs, [first, second])
        XCTAssertEqual(session.entryIDSet, [first, second])
    }

    func test_isFullyEnqueued_becomesTrueOnlyAfterAllGroupsResolved() {
        let session = ImportBatchSession(expectedAssetCount: 3, nonSkippedGroupCount: 2)

        session.markGroupResolved()
        XCTAssertFalse(session.isFullyEnqueued, "只有一群回報，另一群還沒讀完")

        session.markGroupResolved()
        XCTAssertTrue(session.isFullyEnqueued)
    }
}
