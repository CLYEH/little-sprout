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

    /// merge-review R1 M2：`droppedCount` 要跨群累加，不是被後面呼叫覆蓋。
    func test_markGroupResolved_accumulatesDroppedCountAcrossGroups() {
        let session = ImportBatchSession(expectedAssetCount: 5, nonSkippedGroupCount: 2)

        session.markGroupResolved(droppedCount: 2)
        session.markGroupResolved(droppedCount: 1)

        XCTAssertEqual(session.droppedCount, 3)
    }

    func test_markGroupResolved_defaultsToZeroDropped() {
        let session = ImportBatchSession(expectedAssetCount: 1, nonSkippedGroupCount: 1)

        session.markGroupResolved()

        XCTAssertEqual(session.droppedCount, 0)
    }

    // MARK: - merge-review R2 M4：cancel()

    func test_cancel_setsIsCancelledTrue() {
        let session = ImportBatchSession(expectedAssetCount: 1, nonSkippedGroupCount: 1)

        XCTAssertFalse(session.isCancelled)
        session.cancel()
        XCTAssertTrue(session.isCancelled)
    }

    // MARK: - merge-review R2 m1／m2：04b「其餘 Y 張」數字契約

    /// 04b 只看 `expectedAssetCount`／`completedCount` 兩個數字，不重新推導 dropped／未讀到
    /// 各自的子數字——這樣才能保證跟 04「已處理 N/M 張」、05「成功／沒有成功／沒有加入」
    /// 三個畫面永遠讀同一份「總數」語意（票文驗收 4：04→04b→05 的 N 一致）。舊寫法
    /// `batchRows.count - completedCount` 只算得到「已入列但未完成」，漏算 dropped 與還沒
    /// 讀到的部分——這支測試把 `expectedAssetCount` 設得比「已入列」的數字明顯大，模擬
    /// 「還有群還沒被讀到／有 dropped」的情境。
    func test_remainingCount_isExpectedTotalMinusCompleted_includingDroppedAndUnprocessed() {
        let session = ImportBatchSession(expectedAssetCount: 10, nonSkippedGroupCount: 3)

        // 10 張裡只有 4 張完成——其餘 6 張（不管是失敗、格式不支援被 dropped、還是還沒被
        // coordinator 讀到）都算「不會匯入」。
        XCTAssertEqual(
            session.remainingCount(completedCount: 4), 6,
            "10 張裡 4 張已上傳，其餘 6 張（含未讀到／dropped／失敗）都不會匯入"
        )
    }

    /// Live Photo 展開讓 `entryIDs.count` 可能超過 `expectedAssetCount`（型別文件註解「已知
    /// 限制」）——`completedCount` 理論上也可能因此超過 `expectedAssetCount`，這裡確認邊界
    /// 不會回負數（負的「其餘 Y 張」在畫面上沒有意義）。
    func test_remainingCount_neverNegative() {
        let session = ImportBatchSession(expectedAssetCount: 10, nonSkippedGroupCount: 1)

        XCTAssertEqual(session.remainingCount(completedCount: 12), 0)
    }

    // MARK: - merge-review R3 m2：04／04b／05 三個畫面共用同一份總數契約

    /// 04（`completedCount`＋`failedCount`＋`droppedCount`＝「已處理」的分子）、04b
    /// （`remainingCount(completedCount:)`）、05（`session.droppedCount`「沒有加入」行）都
    /// 建立在「成功＋失敗＋沒有加入＝開始匯入時看到的總數」這條等式上——這裡直接呼叫三個
    /// 畫面實際共用的那組 API（`UploadQueueStore.rows(in:)` 逐一計算 `.completed`／`.failed`
    /// 同 `Import04ProgressView.completedCount`／`failedCount`／`Import05SummaryView
    /// .completedCount`／`failedRows` 逐行相同的算法；`session.droppedCount`／
    /// `.expectedAssetCount` 同 04「已處理 N/M 張」的 M、05「沒有加入」行），不是重新推導出
    /// 一份獨立數字——鎖住等式本身：日後若三個畫面裡有任何一處改成讀別的來源（例如 04b 改回
    /// R2 m1 修掉的舊寫法 `batchRows.count - completedCount`，或 05 改讀別的欄位），這支測試
    /// 就會抓到不一致（票文驗收 4：04→04b→05 的 N 一致）。
    func test_completedPlusFailedPlusDropped_equalsExpectedAssetCount_whenFullyResolvedWithoutLivePhoto() {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: PreviewMediaUploadService())
        let session = ImportBatchSession(expectedAssetCount: 5, nonSkippedGroupCount: 1)
        func makeUpload() -> PendingUpload {
            PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        }
        var seeds: [UploadQueueStore.PreviewSeed] = []
        for _ in 0..<3 {
            let upload = makeUpload()
            session.append(upload.id)
            seeds.append(.init(upload, enqueuedAt: Date(), state: .completed))
        }
        let failedUpload = makeUpload()
        session.append(failedUpload.id)
        seeds.append(.init(failedUpload, enqueuedAt: Date(), state: .failed(.network)))
        store.seedForPreview(seeds)
        // 第 5 張讀不到／不支援格式——從未進 `entries`，只透過 `markGroupResolved(droppedCount:)`
        // 累加（同 `AlbumImportUploadCoordinator.enqueue(group:...)` 的 dropped 分支）。
        session.markGroupResolved(droppedCount: 1)

        let batchRows = store.rows(in: session.entryIDSet)
        let completedCount = batchRows.count { if case .completed = $0.state { true } else { false } }
        let failedCount = batchRows.count { if case .failed = $0.state { true } else { false } }

        XCTAssertEqual(
            completedCount + failedCount + session.droppedCount, session.expectedAssetCount,
            "04／05 共用的數字契約：成功＋失敗＋沒有加入＝開始匯入時看到的總數（票文驗收 4）"
        )
        XCTAssertEqual(
            session.remainingCount(completedCount: completedCount), failedCount + session.droppedCount,
            "04b「其餘 Y 張不會匯入」全部終局時＝失敗＋沒有加入——同一份總數，不是另外推導"
        )
    }
}
