import Foundation
@testable import LittleSprout
import XCTest

/// `GrowthStore`：LS-312 R2（merge-review R1 M1／M2，orchestrator 裁決 `824c4aba`）。
///
/// - M1：`GrowthStore.needsRebuild(current:forChildID:)` 是 `ChildGrowthDetailView.
///   loadIfNeeded()` 的核心判斷——同一個孩子（parent 重繪／`ChildrenStore` 頭像簽名 URL
///   重簽）不該重建 store（否則已載入的成長紀錄會被換成全新空 store，畫面誤判成 04 空狀態），
///   換孩子（iPad `regularLayout` 側欄切換）才該重建（否則會顯示上一個孩子的資料）。View 本身
///   沒有 ViewInspector 測不到 `@State` 語意（見 `ImportBatchFlowModifierRegressionTests`
///   文件註解），這支純函式抽出來單獨測。
/// - M2：讀取失敗不能被 `isEmpty` 靜默吞掉——`refresh()` 對外可觀察的行為必須是
///   `loadState == .failure`，`ChildGrowthDetailView.failureBanner(_:)` 依這個狀態渲染
///   錯誤文案＋「重新載入」（見該檔文件註解）。
@MainActor
final class GrowthStoreTests: XCTestCase {
    private struct ThrowingGrowthAPIClient: GrowthAPIClient {
        func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord] {
            throw AppError.network(message: "offline")
        }
    }

    private func makeStore(apiClient: GrowthAPIClient = PreviewGrowthAPIClient()) -> GrowthStore {
        GrowthStore(
            childID: UUID(), childName: "陳小安",
            childBirthday: BirthdayFormat.date(fromWireString: "2025-04-20")!, apiClient: apiClient
        )
    }

    // MARK: - M1：needsRebuild

    func test_needsRebuild_nilCurrent_true() {
        XCTAssertTrue(
            GrowthStore.needsRebuild(current: nil, forChildID: UUID()),
            "還沒有 store（第一次載入這個孩子）就該建一顆"
        )
    }

    /// mutation：若把 `loadIfNeeded()` 改回「一律重建」（原本的 bug），這支測試會抓到——
    /// 同一個孩子的 parent 重繪不該把已載入的 store 換掉。
    func test_needsRebuild_sameChildID_false() {
        let store = makeStore()
        XCTAssertFalse(
            GrowthStore.needsRebuild(current: store, forChildID: store.childID),
            "同一個孩子（childID 相同）不該重建 store——否則 parent 重繪一次成長紀錄就被清空"
        )
    }

    /// mutation：若把判斷改成「只要 current 非 nil 就一律不重建」（只顧 iPhone 忘了 iPad 側欄
    /// 換孩子），這支測試會抓到——换成不同孩子必須重建，否則會顯示上一個孩子的資料。
    func test_needsRebuild_differentChildID_true() {
        let store = makeStore()
        XCTAssertTrue(
            GrowthStore.needsRebuild(current: store, forChildID: UUID()),
            "換了不同孩子（childID 不同）必須重建 store——否則 iPad 側欄切換會顯示錯的孩子"
        )
    }

    // MARK: - M2：讀取失敗態

    /// mutation：若 `refresh()` 的 `catch` 分支被拿掉（錯誤被吞掉、`loadState` 停在
    /// `.submitting` 或悄悄變回 `.idle`），這支測試會抓到。
    func test_refresh_apiClientThrows_setsFailureLoadState() async {
        let store = makeStore(apiClient: ThrowingGrowthAPIClient())

        let succeeded = await store.refresh()

        XCTAssertFalse(succeeded)
        guard case .failure = store.loadState else {
            return XCTFail("loadState 應該是 .failure，實際是 \(store.loadState)——讀取失敗不能被靜默吞成空狀態")
        }
    }

    /// `isEmpty` 不看 `loadState`（04 空狀態骨架＋M2 失敗態要能同時渲染，見 `ChildGrowthDetailView.
    /// failureBanner(_:)` 疊在骨架卡上方，不是整頁換掉）——讀取失敗時 `records` 仍是空陣列，
    /// `isEmpty` 應該維持 `true`。
    func test_refresh_apiClientThrows_isEmptyStaysTrue() async {
        let store = makeStore(apiClient: ThrowingGrowthAPIClient())

        _ = await store.refresh()

        XCTAssertTrue(store.isEmpty, "失敗態的骨架卡仍要渲染——isEmpty 不該因為失敗就變成別的東西")
    }
}
