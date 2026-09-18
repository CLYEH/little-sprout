import Foundation
@testable import LittleSprout
import XCTest

/// `GrowthStore`：LS-312 R2（merge-review R1 M1／M2，orchestrator 裁決 `824c4aba`）＋
/// LS-313（新增／編輯／刪除量測三個寫入方法）。
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
/// - LS-313：`save(_:)`／`delete(id:)` 成功後直接更新本地 `records`（不重新 `refresh()`，見
///   `GrowthStore` 型別文件註解）——02／03 儲存或刪除後 01／06 要「即時更新」的行為面保證。
@MainActor
final class GrowthStoreTests: XCTestCase {
    private struct ThrowingGrowthAPIClient: GrowthAPIClient {
        func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord] {
            throw AppError.network(message: "offline")
        }

        func upsertGrowthRecord(childID: UUID, input: GrowthMeasurementInput) async throws -> GrowthRecord {
            throw AppError.network(message: "offline")
        }

        func deleteGrowthRecord(id: UUID) async throws {
            throw AppError.network(message: "offline")
        }
    }

    /// LS-313：`save(_:)`／`delete(id:)` 測試用的可控 stub——`upsertResult`／`deleteResult`
    /// 在呼叫前先設好，測試方法本身是唯一的寫入者（同 `PreviewGrowthAPIClient` 的
    /// `@unchecked Sendable` 既有理由，不是真的要處理併發存取）。
    private final class StubGrowthAPIClient: GrowthAPIClient, @unchecked Sendable {
        var upsertResult: Result<GrowthRecord, Error> = .failure(AppError.network(message: "not configured"))
        var deleteResult: Result<Void, Error> = .success(())

        func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord] { [] }

        func upsertGrowthRecord(childID: UUID, input: GrowthMeasurementInput) async throws -> GrowthRecord {
            try upsertResult.get()
        }

        func deleteGrowthRecord(id: UUID) async throws {
            try deleteResult.get()
        }
    }

    private func makeStore(apiClient: GrowthAPIClient = PreviewGrowthAPIClient()) -> GrowthStore {
        GrowthStore(
            childID: UUID(), childName: "陳小安",
            childBirthday: BirthdayFormat.date(fromWireString: "2025-04-20")!, apiClient: apiClient
        )
    }

    private static func record(
        id: UUID = UUID(), childID: UUID, measuredOn: String = "2026-08-20", heightCm: Double? = 78.5
    ) -> GrowthRecord {
        let date = BirthdayFormat.date(fromWireString: measuredOn)!
        return GrowthRecord(
            id: id, familyID: UUID(), childID: childID, authorID: UUID(), measuredOn: date,
            heightCm: heightCm, weightKg: nil, headCm: nil, note: nil, createdAt: date, updatedAt: date
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

    // MARK: - LS-313：save(_:) 新增

    /// mutation：若 `save(_:)` 新增分支不把回傳的整列 `append` 進 `records`（例如漏寫這一步），
    /// 這支測試會抓到——票文範圍 3「儲存後 01／06 的區塊與曲線要即時更新」的核心保證。
    func test_save_newRecord_appendsToRecords() async {
        let store = makeStore(apiClient: PreviewGrowthAPIClient())
        XCTAssertTrue(store.records.isEmpty)

        let succeeded = await store.save(
            GrowthMeasurementInput(id: nil, measuredOn: Date(), heightCm: 78.5, weightKg: 9.6, headCm: 45.0, note: nil)
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.records.count, 1, "新增成功後 records 應該多一筆，不是停在原本的空陣列")
        XCTAssertEqual(store.records.first?.heightCm, 78.5)
    }

    /// mutation：若 `save(_:)` 編輯分支改成一律 `append`（不判斷 `id` 是否已存在），這支測試
    /// 會抓到——編輯既有筆不該讓 `records` 多一筆重複的。
    func test_save_editingExistingRecord_replacesInPlaceNotAppends() async {
        let stub = StubGrowthAPIClient()
        let store = makeStore(apiClient: stub)
        let existingID = UUID()
        let original = Self.record(id: existingID, childID: store.childID, heightCm: 70.0)
        store.seedForPreview(records: [original])
        let edited = Self.record(id: existingID, childID: store.childID, heightCm: 75.0)
        stub.upsertResult = .success(edited)

        let succeeded = await store.save(
            GrowthMeasurementInput(
                id: existingID, measuredOn: edited.measuredOn, heightCm: 75.0, weightKg: nil, headCm: nil, note: nil
            )
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.records.count, 1, "編輯既有筆不該讓 records 多一筆——應該是同一個 id 被替換")
        XCTAssertEqual(store.records.first?.heightCm, 75.0, "曲線／最新值卡要讀到編輯後的新值")
    }

    /// mutation：若 `save(_:)` 的 `catch` 分支被拿掉，這支測試會抓到——同 M2 讀取失敗的既有精神。
    func test_save_apiClientThrows_setsFailureSaveState() async {
        let store = makeStore(apiClient: ThrowingGrowthAPIClient())

        let succeeded = await store.save(
            GrowthMeasurementInput(id: nil, measuredOn: Date(), heightCm: 78.5, weightKg: nil, headCm: nil, note: nil)
        )

        XCTAssertFalse(succeeded)
        guard case .failure = store.saveState else {
            return XCTFail("saveState 應該是 .failure，實際是 \(store.saveState)")
        }
        XCTAssertTrue(store.records.isEmpty, "送出失敗不該憑空多一筆本地紀錄")
    }

    /// `resetSaveState()` 只清 `.failure`——同 `ChildrenStore.resetCreateState()` 既有理由，
    /// 不該把 `.success` 悄悄打斷。
    func test_resetSaveState_onlyClearsFailure() async {
        let store = makeStore(apiClient: ThrowingGrowthAPIClient())
        _ = await store.save(
            GrowthMeasurementInput(id: nil, measuredOn: Date(), heightCm: 78.5, weightKg: nil, headCm: nil, note: nil)
        )
        guard case .failure = store.saveState else { return XCTFail("前置條件：saveState 應該先是 .failure") }

        store.resetSaveState()

        XCTAssertEqual(store.saveState, .idle)
    }

    // MARK: - LS-313：delete(id:) 軟刪

    /// mutation：若 `delete(id:)` 成功後不把那一筆從 `records` 移除，這支測試會抓到——票文
    /// 範圍 3「軟刪後列表與曲線即時更新」。
    func test_delete_success_removesFromRecords() async {
        let stub = StubGrowthAPIClient()
        let store = makeStore(apiClient: stub)
        let targetID = UUID()
        let target = Self.record(id: targetID, childID: store.childID)
        let other = Self.record(childID: store.childID, measuredOn: "2025-05-20")
        store.seedForPreview(records: [target, other])
        stub.deleteResult = .success(())

        let succeeded = await store.delete(id: targetID)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.records.map(\.id), [other.id], "只有被刪的那一筆該消失，另一筆要維持在案")
    }

    /// mutation：若 `delete(id:)` 的 `catch` 分支被拿掉，這支測試會抓到。
    func test_delete_apiClientThrows_setsFailureDeleteStateAndKeepsRecord() async {
        let stub = StubGrowthAPIClient()
        let store = makeStore(apiClient: stub)
        let targetID = UUID()
        let target = Self.record(id: targetID, childID: store.childID)
        store.seedForPreview(records: [target])
        stub.deleteResult = .failure(AppError.rejected(message: "沒有權限", code: "42501"))

        let succeeded = await store.delete(id: targetID)

        XCTAssertFalse(succeeded)
        guard case .failure = store.deleteState else {
            return XCTFail("deleteState 應該是 .failure，實際是 \(store.deleteState)")
        }
        XCTAssertEqual(store.records.map(\.id), [targetID], "刪除失敗這筆紀錄不該從本地 records 消失")
    }

    /// `resetDeleteState()` 只清 `.failure`，同 `resetSaveState()`。
    func test_resetDeleteState_onlyClearsFailure() async {
        let stub = StubGrowthAPIClient()
        let store = makeStore(apiClient: stub)
        let targetID = UUID()
        store.seedForPreview(records: [Self.record(id: targetID, childID: store.childID)])
        stub.deleteResult = .failure(AppError.rejected(message: "沒有權限", code: "42501"))
        _ = await store.delete(id: targetID)
        guard case .failure = store.deleteState else { return XCTFail("前置條件：deleteState 應該先是 .failure") }

        store.resetDeleteState()

        XCTAssertEqual(store.deleteState, .idle)
    }
}
