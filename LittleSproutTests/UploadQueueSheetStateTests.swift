import Foundation
@testable import LittleSprout
import XCTest

/// LS-410（`design/littlesprout.pen` Notes `k4oJhV`）：上傳佇列 sheet 的三態只在打開時判定一次；群標題列與
/// 重試槽的存在也在打開時決定（停留期間不增減行）。文案逐字取自稿面（U+2060／NBSP codepoint）。
@MainActor
final class UploadQueueSheetStateTests: XCTestCase {
    private func snapshot(
        inFlight: Int = 0, failed: Int = 0, retryable: Int = 0, completed: Int = 0
    ) -> UploadQueueSheetSnapshot {
        UploadQueueSheetSnapshot(inFlight: inFlight, failed: failed, retryableFailed: retryable, completed: completed)
    }

    func test_mode_threeStates() {
        XCTAssertEqual(
            snapshot(inFlight: 5, failed: 3, retryable: 2, completed: 4).mode, .progress,
            "有進行中：即使有失敗仍是進行中態（rU2zY）"
        )
        XCTAssertEqual(snapshot(failed: 3, retryable: 2, completed: 4).mode, .onlyFailed, "沒有進行中、有失敗（KaONe）")
        XCTAssertEqual(snapshot(completed: 4).mode, .allDone, "沒有進行中、沒有失敗、K>0（sq2SF）")
    }

    func test_footerTitle_onlyProgressModeKeepsBackgroundContinue() {
        XCTAssertEqual(snapshot(inFlight: 1).footerTitle, UploadQueueSheetCopy.footerContinue)
        XCTAssertEqual(snapshot(failed: 1, completed: 2).footerTitle, "關閉")
        XCTAssertEqual(snapshot(completed: 2).footerTitle, "關閉")
        XCTAssertEqual(UploadQueueSheetCopy.plain(UploadQueueSheetCopy.footerContinue), "在背景繼續，關閉視窗")
    }

    /// 群標題列（右端「× 移除這 N 張」）與重試槽只在打開時失敗數 >1（重試槽另需有可重試的）才建立。
    func test_batchRowAndRetrySlot_decidedAtOpen() {
        XCTAssertFalse(snapshot(failed: 1, retryable: 1).hasBatchRemoveRow, "單一失敗：那一列自己的「移除」就夠了")
        XCTAssertFalse(snapshot(failed: 1, retryable: 1).hasRetrySlot)
        XCTAssertTrue(snapshot(failed: 2, retryable: 0).hasBatchRemoveRow, "兩張都是 LS002：有批次移除、沒有重試槽")
        XCTAssertFalse(snapshot(failed: 2, retryable: 0).hasRetrySlot)
        XCTAssertTrue(snapshot(failed: 3, retryable: 2).hasBatchRemoveRow)
        XCTAssertTrue(snapshot(failed: 3, retryable: 2).hasRetrySlot)
    }

    func test_snapshotFromStore_readsQueueCounts() {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: StubMediaUploadService())
        store.seedForPreview((0..<3).map { index in
            .init(
                PendingUpload(
                    kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                    pixelSize: PixelSize(width: 4, height: 3)
                ),
                enqueuedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                state: index == 2 ? .completed : .failed(.network)
            )
        })
        let opened = UploadQueueSheetSnapshot(store: store)
        XCTAssertEqual(opened.mode, .onlyFailed)
        XCTAssertTrue(opened.hasBatchRemoveRow)
        XCTAssertTrue(opened.hasRetrySlot)
    }

    // MARK: - 文案

    func test_onlyFailedTitle_countAndAllRemovedTransition() {
        XCTAssertEqual(
            UploadQueueSheetCopy.plain(UploadQueueSheetCopy.onlyFailedTitle(failed: 3)), "有 3 張照片沒有加進去"
        )
        XCTAssertEqual(
            UploadQueueSheetCopy.onlyFailedTitle(failed: 3),
            "有\u{2060}\u{A0}\u{2060}3\u{2060}\u{A0}\u{2060}張\u{2060}照\u{2060}片沒\u{2060}有\u{2060}加\u{2060}進\u{2060}去",
            "稿面 ri0AF 標題 codepoint"
        )
        XCTAssertEqual(
            UploadQueueSheetCopy.plain(UploadQueueSheetCopy.onlyFailedTitle(failed: 0)), "這幾張不加進相簿了",
            "全部標記移除（M＝0）：過渡句，不宣稱都加好了"
        )
        XCTAssertEqual(
            UploadQueueSheetCopy.plain(UploadQueueSheetCopy.onlyFailedMain(failed: 0)),
            "照片還在手機裡。關閉這個視窗前，都可以按「復原」放回來。",
            "x2it3Q 主行取 R3 版本（merge-review m1：不是 R2 舊句）"
        )
        XCTAssertEqual(
            UploadQueueSheetCopy.plain(UploadQueueSheetCopy.onlyFailedMain(failed: 3)),
            "看每張的原因，可以再試一次；不要的就移除，照片還在手機裡。"
        )
    }

    func test_otherCopy() {
        XCTAssertEqual(UploadQueueSheetCopy.plain(UploadQueueSheetCopy.noRetry), "沒有能重試的照片")
        XCTAssertEqual(UploadQueueSheetCopy.plain(UploadQueueSheetCopy.tombstoneText), "已移除，不會加進相簿。")
        XCTAssertEqual(UploadQueueSheetCopy.plain(UploadQueueSheetCopy.batchRemoveTitle(count: 3)), "移除這 3 張")
        XCTAssertEqual(UploadQueueSheetCopy.confirmTitle(count: 3), "移除這 3 張照片？")
        XCTAssertEqual(UploadQueueSheetCopy.confirmAction(count: 3), "移除這 3 張")
        XCTAssertEqual(UploadQueueSheetCopy.plain(UploadQueueSheetCopy.allDoneMain(completed: 4)), "4 張都加進相簿了")
        XCTAssertEqual(
            UploadQueueSheetCopy.plain(UploadQueueSheetCopy.breakdown(waiting: 1, uploading: 1)),
            "1 張等候上傳、1 張上傳中"
        )
        XCTAssertEqual(UploadQueueSheetCopy.plain(UploadQueueSheetCopy.breakdown(waiting: 0, uploading: 2)), "2 張上傳中")
        XCTAssertEqual(UploadQueueSheetCopy.breakdown(waiting: 0, uploading: 0), "")
    }
}
