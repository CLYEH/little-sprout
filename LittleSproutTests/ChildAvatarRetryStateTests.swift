@testable import LittleSprout
import XCTest

/// `ChildAvatarView` 的 `AsyncImage` 載入失敗自動重試一次（LS-293，源自 LS-273 merge-review R1
/// `498c8e5a` i1）：抽出來的純狀態機 `ChildAvatarRetryState` 決定「這次 `.failure` phase 該不該
/// 觸發重試」。這裡直接餵一段可注入的 phase 決策序列驗證，不架設 URLProtocol stub 去驅動
/// `AsyncImage` 內部真正的下載 task——同 `ChildAvatarViewStructureTests` 檔頭的理由：這類時序
/// 在 `UIHostingController` 裡單獨渲染重現不出來，行為測試守不住實際渲染路徑，能守住的是
/// 「重試邏輯本身只觸發一次」這個不變量（`ChildAvatarView.scheduleRetryIfNeeded()` 直接呼叫
/// 同一個 `shouldRetry()`，兩邊共用同一份判斷）。
final class ChildAvatarRetryStateTests: XCTestCase {
    /// mutation：把 `ChildAvatarRetryState.shouldRetry()` 改成恆回 false（拿掉重試）——
    /// 第一條斷言會紅（`XCTAssertTrue` 落空）。
    func test_shouldRetry_firstFailureRetriesOnceThenStops() {
        var state = ChildAvatarRetryState()

        XCTAssertTrue(state.shouldRetry(), "第一次 .failure 應該觸發重試")
        XCTAssertFalse(state.shouldRetry(), "已經重試過一次，第二次失敗不該再重試——直接顯示縮寫")
        XCTAssertFalse(state.shouldRetry(), "重試過一次之後恆為 false，不會無限重試")
    }

    /// 可注入的 phase 序列：`.failure` → 重試一次 → `.success`。
    func test_phaseSequence_failureThenSuccess_retriesExactlyOnce() {
        var state = ChildAvatarRetryState()
        var retryCount = 0

        func handle(_ phase: MockPhase) {
            guard phase == .failure, state.shouldRetry() else { return }
            retryCount += 1
        }

        handle(.failure)
        handle(.success)

        XCTAssertEqual(retryCount, 1, "失敗一次接著成功，只該重試一次")
    }

    /// 可注入的 phase 序列：連續 `.failure` 三次，重試只該發生在第一次。
    func test_phaseSequence_failureRepeatedly_retriesOnlyOnce() {
        var state = ChildAvatarRetryState()
        var retryCount = 0

        func handle(_ phase: MockPhase) {
            guard phase == .failure, state.shouldRetry() else { return }
            retryCount += 1
        }

        handle(.failure)
        handle(.failure)
        handle(.failure)

        XCTAssertEqual(retryCount, 1, "重試過一次之後就算持續失敗也不該再觸發第二次——第二次失敗要顯示縮寫")
    }

    private enum MockPhase: Equatable {
        case failure
        case success
    }
}
