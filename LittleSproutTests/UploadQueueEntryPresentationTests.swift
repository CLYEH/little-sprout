import Foundation
@testable import LittleSprout
import XCTest

/// LS-404（`design/littlesprout.pen` LS-402 Notes `OT5n9`／`bqnO1`／`kI2bt`）：設定頁上傳佇列入口列的
/// 四態判定、文案逐字、停留期間狀態機（含 C1a「列高相同才原地換態，否則等情境邊界」）與 store 接線。
///
/// 為什麼要這些測試：入口列「停留期間不搬動頁面」是長輩使用的穩定性承諾（brand 十條 #10）；狀態機的守門
/// （行數類別＋實測列高）一旦被拿掉，iPad 側欄會在使用者眼前 100→125 跳一下，而畫面上看不出哪裡壞了。
@MainActor
final class UploadQueueEntryPresentationTests: XCTestCase {
    private func counts(
        waiting: Int = 0, uploading: Int = 0, failed: Int = 0, completed: Int = 0
    ) -> UploadQueueEntryCounts {
        UploadQueueEntryCounts(waiting: waiting, uploading: uploading, failed: failed, completed: completed)
    }

    private func state(after boundary: UploadQueueEntryCounts) -> UploadQueueEntryState {
        var state = UploadQueueEntryState()
        state.contextBoundary(boundary)
        return state
    }

    // MARK: - 四態判定（OT5n9／kI2bt ②）

    func test_phase_fourStatesAndEmpty() {
        XCTAssertEqual(counts(waiting: 25, uploading: 2, completed: 3).phase, .inProgress)
        XCTAssertEqual(counts(waiting: 25, uploading: 1, failed: 1, completed: 3).phase, .inProgressWithFailure)
        XCTAssertEqual(counts(failed: 1, completed: 29).phase, .onlyFailed)
        XCTAssertEqual(counts(completed: 30).phase, .allDone)
        XCTAssertNil(counts().phase, "佇列空＝沒有東西可顯示")
        XCTAssertEqual(counts(waiting: 25, uploading: 2, failed: 0, completed: 3).remaining, 27, "板上「30 張已完成 3」N＝27")
    }

    // MARK: - 文案逐字（稿面 codepoint：NBSP U+00A0、語意斷點 U+2060）

    func test_copy_matchesDesignCodepointsVerbatim() {
        let inProgress = counts(waiting: 25, uploading: 2, completed: 3)
        XCTAssertEqual(
            UploadQueueEntryCopy.label(.inProgress, inProgress),
            "\u{6B63}\u{2060}\u{5728}\u{65B0}\u{2060}\u{589E}\u{2060}\u{7167}\u{2060}\u{7247}"
        )
        XCTAssertEqual(
            UploadQueueEntryCopy.value(.inProgress, inProgress),
            "\u{9084}\u{6709}\u{A0}27\u{A0}\u{5F35}\u{9084}\u{2060}\u{6C92}\u{2060}\u{5B8C}\u{2060}\u{6210}"
        )
        XCTAssertNil(UploadQueueEntryCopy.failureLine(.inProgress, inProgress))

        let withFailure = counts(waiting: 25, uploading: 1, failed: 1, completed: 3)
        XCTAssertEqual(
            UploadQueueEntryCopy.failureLine(.inProgressWithFailure, withFailure),
            "1\u{A0}\u{5F35}\u{6C92}\u{2060}\u{6709}\u{2060}\u{6210}\u{2060}\u{529F}"
        )

        let onlyFailed = counts(failed: 1, completed: 29)
        XCTAssertEqual(
            UploadQueueEntryCopy.label(.onlyFailed, onlyFailed),
            "\u{6709}\u{A0}1\u{A0}\u{5F35}\u{2060}\u{7167}\u{2060}\u{7247}\u{6C92}\u{2060}\u{6709}"
                + "\u{2060}\u{52A0}\u{2060}\u{9032}\u{2060}\u{53BB}"
        )
        XCTAssertEqual(
            UploadQueueEntryCopy.value(.onlyFailed, onlyFailed),
            // LS-410（C2a，與 sheet 移除功能同版上線）：「看原因，再試或移除」，取代 LS-404 的「看原因，或再試一次」。
            "\u{770B}\u{2060}\u{539F}\u{2060}\u{56E0}\u{2060}\u{FF0C}\u{518D}\u{2060}\u{8A66}"
                + "\u{2060}\u{6216}\u{2060}\u{79FB}\u{2060}\u{9664}"
        )

        let done = counts(completed: 30)
        XCTAssertEqual(
            UploadQueueEntryCopy.label(.allDone, done),
            "\u{7167}\u{2060}\u{7247}\u{2060}\u{90FD}\u{52A0}\u{2060}\u{597D}\u{2060}\u{4E86}"
        )
        XCTAssertEqual(
            UploadQueueEntryCopy.value(.allDone, done),
            "30\u{A0}\u{5F35}\u{2060}\u{90FD}\u{52A0}\u{2060}\u{9032}\u{2060}\u{76F8}\u{2060}\u{7C3F}\u{2060}\u{4E86}"
        )
    }

    /// 失敗顯眼度不變式（OT5n9）：只要還有失敗項，畫面上一定有含失敗數的失敗句（進行中＋失敗的第三行、
    /// 只剩失敗的 Label）——紅字不會在「只剩這張要處理」時消失。
    func test_failureSignalNeverDisappearsWhileFailedRemains() {
        for phase in [UploadQueueEntryPhase.inProgressWithFailure, .onlyFailed] {
            let sample = counts(waiting: phase == .onlyFailed ? 0 : 5, failed: 12, completed: 3)
            let visible = [
                UploadQueueEntryCopy.label(phase, sample), UploadQueueEntryCopy.failureLine(phase, sample) ?? ""
            ]
            XCTAssertTrue(visible.contains { $0.contains("12") && $0.contains("\u{2060}") }, "\(phase) 應顯示含失敗張數的失敗句")
        }
        XCTAssertEqual(
            UploadQueueEntryCopy.accessibilityLabel(.onlyFailed, counts(failed: 1, completed: 29)),
            "有 1 張照片沒有加進去，看原因，再試或移除"
        )
    }

    // MARK: - 情境邊界（bqnO1）

    func test_boundary_showsLivePhase_andHidesWhenNothingToShow() {
        XCTAssertEqual(state(after: counts(waiting: 3, uploading: 1)).phase, .inProgress)
        XCTAssertEqual(state(after: counts(failed: 2, completed: 5)).phase, .onlyFailed)
        XCTAssertNil(state(after: counts(completed: 30)).phase, "進入設定頁時佇列早已全部完成＝不顯示（過渡態只在停留中出現）")
        XCTAssertNil(state(after: .zero).phase)
    }

    /// LS-404 merge-review m2（LS-410 收斂）：「全部完成」過渡態只在停留期間原地換態時出現；情境邊界（離開再回來、
    /// 關 sheet）遇到全部完成一律隱藏，不再多顯示一次「照片都加好了」（Notes `bqnO1`：邊界即隱藏）。
    func test_boundary_whenEverythingCompleted_hidesInsteadOfShowingAllDoneAgain() {
        var state = state(after: counts(waiting: 3, completed: 2))
        state.contextBoundary(counts(completed: 5)) // 離開再回來（或關 sheet）時已全部完成
        XCTAssertNil(state.phase, "邊界遇到全部完成：直接隱藏（修前會多顯示一次 .allDone）")
        state.contextBoundary(counts(completed: 5))
        XCTAssertNil(state.phase, "已隱藏後不會因為 completed 還在就又冒出來")
    }

    /// 停留期間原地換成「全部完成」之後，下一個情境邊界才依出現條件隱藏。
    func test_allDone_reachedInPlaceDuringStay_hidesAtNextBoundary() {
        var state = state(after: counts(waiting: 3, completed: 2))
        state.liveChanged(counts(completed: 5)) { _ in 75 }
        XCTAssertEqual(state.phase, .allDone)
        state.contextBoundary(counts(completed: 5))
        XCTAssertNil(state.phase)
    }

    /// LS-410 i2：sheet 內把失敗項全部移除（K>0 已有完成過的）→ 關閉 sheet 的邊界，入口列直接隱藏，
    /// 不經過對剛放棄的照片不成立的「照片都加好了」過渡態（Notes `Fq494`）。
    func test_boundary_afterAllFailedRemoved_hidesEntryRow_evenWhenSomeWereCompleted() {
        var state = state(after: counts(failed: 3, completed: 4)) // 只剩失敗態
        XCTAssertEqual(state.phase, .onlyFailed)
        state.contextBoundary(counts(failed: 0, completed: 4)) // sheet 關閉：commitRemovals 之後的快照
        XCTAssertNil(state.phase, "全部移除後入口列直接隱藏（不論 K）")
    }

    /// 移除一部分：仍有失敗＝只剩失敗態、M 更新（Notes `oQ5SF`）。
    func test_boundary_afterSomeFailedRemoved_keepsOnlyFailedWithUpdatedCount() {
        var state = state(after: counts(failed: 3, completed: 4))
        state.contextBoundary(counts(failed: 1, completed: 4))
        XCTAssertEqual(state.phase, .onlyFailed)
        XCTAssertEqual(UploadQueueEntryCopy.accessibilityLabel(.onlyFailed, counts(failed: 1, completed: 4)),
                       "有 1 張照片沒有加進去，看原因，再試或移除")
    }

    /// 移除後仍有進行中：回到進行中態（移除的失敗項不再算在 N 裡）。
    func test_boundary_afterFailedRemoved_withInFlightLeft_showsInProgress() {
        var state = state(after: counts(waiting: 2, failed: 2, completed: 3))
        XCTAssertEqual(state.phase, .inProgressWithFailure)
        state.contextBoundary(counts(waiting: 2, failed: 0, completed: 3))
        XCTAssertEqual(state.phase, .inProgress)
    }

    func test_boundary_afterAllDone_newUploadShowsInProgressAgain() {
        var state = state(after: counts(waiting: 1))
        state.liveChanged(counts(completed: 1)) { _ in 75 }
        state.contextBoundary(counts(completed: 1))
        state.contextBoundary(counts(waiting: 4, completed: 1))
        XCTAssertEqual(state.phase, .inProgress)
    }

    // MARK: - 停留期間（列高判準，C1a）

    func test_stay_sameHeight_inProgressToAllDone_switchesInPlace() {
        var state = state(after: counts(waiting: 2, uploading: 1, completed: 3))
        state.liveChanged(counts(completed: 6)) { _ in 75 }
        XCTAssertEqual(state.phase, .allDone, "兩行態之間列高相同：原地換成「照片都加好了」")
    }

    /// C1a：iPad 側欄進行中 100、只剩失敗 125（Label 斷成兩行）——列高不同不原地換態，等情境邊界。
    func test_stay_differentHeight_inProgressToOnlyFailed_doesNotSwitchInPlace_untilBoundary() {
        var state = state(after: counts(waiting: 1, uploading: 1, completed: 3))
        let heights: [UploadQueueEntryPhase: CGFloat] = [.inProgress: 100, .onlyFailed: 125]
        state.liveChanged(counts(failed: 1, completed: 4)) { heights[$0] }
        XCTAssertEqual(state.phase, .inProgress, "列高不同（100→125）：停留期間維持原態，不搬動 Nav List")
        state.contextBoundary(counts(failed: 1, completed: 4))
        XCTAssertEqual(state.phase, .onlyFailed, "情境邊界才換態")
    }

    func test_stay_sameHeight_inProgressToOnlyFailed_switchesInPlace() {
        var state = state(after: counts(waiting: 1, uploading: 1, completed: 3))
        state.liveChanged(counts(failed: 1, completed: 4)) { _ in 75 }
        XCTAssertEqual(state.phase, .onlyFailed, "iPhone 預設字級兩行態列高相同：原地換成紅字失敗句")
    }

    /// 行數類別不同（多／少一行）一律等邊界，即使量到的列高恰好相同也不換。
    func test_stay_lineCountChange_neverSwitchesInPlace() {
        var addFailure = state(after: counts(waiting: 5, completed: 3))
        addFailure.liveChanged(counts(waiting: 4, failed: 1, completed: 3)) { _ in 75 }
        XCTAssertEqual(addFailure.phase, .inProgress, "進行中→進行中＋失敗（多一行）：等邊界")

        var dropFailure = state(after: counts(waiting: 5, failed: 1, completed: 3))
        dropFailure.liveChanged(counts(failed: 1, completed: 8)) { _ in 75 }
        XCTAssertEqual(dropFailure.phase, .inProgressWithFailure, "進行中＋失敗→只剩失敗（少一行）：等邊界，紅字失敗行不中斷")
    }

    func test_stay_unmeasuredHeight_waitsInsteadOfGuessing() {
        var state = state(after: counts(waiting: 2, completed: 3))
        state.liveChanged(counts(completed: 5)) { $0 == .inProgress ? 75 : nil }
        XCTAssertEqual(state.phase, .inProgress)
    }

    func test_stay_hiddenRowStaysHidden_noRowAppearsMidStay() {
        var state = UploadQueueEntryState()
        state.liveChanged(counts(waiting: 3)) { _ in 75 }
        XCTAssertNil(state.phase, "停留期間不增行（brand 十條 #10）")
    }

    // MARK: - store 接線（kI2bt ②③）

    private func makeStore(_ states: [UploadItemState]) -> UploadQueueStore {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: StubMediaUploadService())
        store.seedForPreview(states.enumerated().map { index, state in
            .init(
                PendingUpload(
                    kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                    pixelSize: PixelSize(width: 4, height: 3)
                ),
                enqueuedAt: Date(timeIntervalSince1970: TimeInterval(index)), state: state
            )
        })
        return store
    }

    func test_countsFromStore_completedIsEntriesMinusRemaining() {
        let store = makeStore([.completed, .completed, .waiting, .uploading(progress: nil), .failed(.network)])
        let counts = UploadQueueEntryCounts(store: store)
        XCTAssertEqual(counts, UploadQueueEntryCounts(waiting: 1, uploading: 1, failed: 1, completed: 2))
        XCTAssertEqual(counts.completed, store.entries.count - store.remainingCount)
        XCTAssertEqual(UploadQueueEntryCounts(store: nil), .zero)
    }

    /// LS-410：sheet 開著時標記移除，入口列背後的計數不能變（否則 `liveChanged` 會在 sheet 後面先把列原地換成
    /// 「全部完成」，見 merge-review i2 的 PLAUSIBLE）；`commitRemovals` 之後才反映（sheet 關閉的邊界重新快照）。
    func test_countsFromStore_markingDoesNotChangeEntryCounts_untilCommit() {
        let store = makeStore([.completed, .completed, .failed(.network), .failed(.quota)])
        let before = UploadQueueEntryCounts(store: store)
        XCTAssertEqual(before, UploadQueueEntryCounts(waiting: 0, uploading: 0, failed: 2, completed: 2))

        store.markAllFailedRemoved()
        XCTAssertEqual(UploadQueueEntryCounts(store: store), before, "標記階段入口列計數不動＝不會在 sheet 後面換態")

        store.commitRemovals()
        let after = UploadQueueEntryCounts(store: store)
        XCTAssertEqual(after, UploadQueueEntryCounts(waiting: 0, uploading: 0, failed: 0, completed: 2))
        var state = UploadQueueEntryState()
        state.contextBoundary(before)
        state.contextBoundary(after)
        XCTAssertNil(state.phase, "提交後的邊界：全部移除，入口列隱藏")
    }

    /// 「回前景」邊界靠這個遞增（在重送翻回等候之後才評估）：沒有項目要重送時也要遞增。
    func test_appDidBecomeActive_alwaysBumpsForegroundEpoch() {
        let store = makeStore([.completed])
        XCTAssertEqual(store.resume.foregroundEpoch, 0)
        store.appDidBecomeActive()
        XCTAssertEqual(store.resume.foregroundEpoch, 1)
        store.appDidEnterBackground()
        store.appDidBecomeActive()
        XCTAssertEqual(store.resume.foregroundEpoch, 2)
    }

    func test_entryThumbnailID_picksUploadingThenFirstFailedThenLastCompleted() {
        let store = makeStore([
            .completed, .completed, .waiting, .uploading(progress: nil), .failed(.network), .failed(.quota)
        ])
        let ids = store.order
        XCTAssertEqual(store.entryThumbnailID(for: .inProgress), ids[3], "正在上傳那張")
        XCTAssertEqual(store.entryThumbnailID(for: .inProgressWithFailure), ids[3])
        XCTAssertEqual(store.entryThumbnailID(for: .onlyFailed), ids[4], "第一張失敗的")
        XCTAssertEqual(store.entryThumbnailID(for: .allDone), ids[1], "最後完成那張")
    }
}
