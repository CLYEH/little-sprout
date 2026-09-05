import Foundation
@testable import LittleSprout
import os
import XCTest

/// merge-review R1 M1：`refreshQuota()` 原本少了 `refreshLatestInvite` 那套「await 前後核對」
/// 防線——使用者在 09 頁停留、`fetchQuota` 在飛、這段期間登出（`SettingsView.signOut()` 呼叫
/// `familyStore.reset()`）：舊寫法會把前一位使用者家庭的用量／上限寫回已經被 reset 過的
/// store。這裡用可控 gate（同 `FamilyStoreInviteRaceTests` 的既有作法）卡住 `fetchQuota`，
/// 在它還沒回來時呼叫 `reset()`／換家庭，驗證結果不會被寫回、`quotaState` 落回中性的
/// `.idle`。
@MainActor
final class FamilyStoreRefreshQuotaRaceTests: XCTestCase {
    private let familyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func makeFamily(id: UUID? = nil, name: String = "陳家") -> Family {
        Family(id: id ?? familyID, name: name, createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    /// 等 `quotaState` 進入 `.submitting`——不用固定 `sleep`，輪詢逾時才失敗，同
    /// `FamilyStoreInviteRaceTests` 既有的等待寫法。
    private func waitForQuotaSubmitting(
        _ store: FamilyStore, gateContinuation: AsyncStream<Void>.Continuation,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        var iterations = 0
        while store.quotaState != .submitting {
            iterations += 1
            guard iterations < 200 else {
                gateContinuation.finish()
                XCTFail("等待 quotaState 進入 .submitting 逾時", file: file, line: line)
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    func test_refreshQuota_resetDuringInFlightFetch_discardsStaleResultAndFallsBackToIdle() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        await store.refreshMyFamily()

        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setFetchQuotaHandler { _ in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return FamilyQuota(usedBytes: 5_368_709_120, quotaBytes: 5_368_709_120)
        }

        let refreshTask = Task { await store.refreshQuota() }
        guard await waitForQuotaSubmitting(store, gateContinuation: gateContinuation) else { return }

        // 使用者在飛行期間登出——`reset()` 把 quota 清空、ownerUserID／myFamily 歸零。
        store.reset()

        gateContinuation.finish()
        let result = await refreshTask.value

        XCTAssertNil(result, "reset 之後不該回傳前一位使用者的用量")
        XCTAssertNil(store.quota, "過期的 fetchQuota 結果不該覆寫已經被 reset 的 quota")
        XCTAssertEqual(
            store.quotaState, .idle,
            "過期結果應該讓 quotaState 落回中性的 .idle，不是卡在 .submitting 或寫入 .success"
        )
    }

    func test_refreshQuota_familyChangedDuringInFlightFetch_discardsStaleResult() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        await store.refreshMyFamily()

        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setFetchQuotaHandler { _ in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return FamilyQuota(usedBytes: 1, quotaBytes: 2)
        }

        let refreshTask = Task { await store.refreshQuota() }
        guard await waitForQuotaSubmitting(store, gateContinuation: gateContinuation) else { return }

        // 同一個使用者換了一個新家庭（例如切換帳號後 syncOwner 重查到不同 family）——
        // `refreshMyFamily()` 沒有 `lookupState.isSubmitting` 擋著（上一次呼叫已完成），
        // 這裡直接呼叫模擬「查到不同家庭」。
        let otherFamilyID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let otherFamily = makeFamily(id: otherFamilyID, name: "林家")
        stub.setFetchMyFamilyHandler { otherFamily }
        await store.refreshMyFamily()

        gateContinuation.finish()
        _ = await refreshTask.value

        XCTAssertNil(store.quota, "過期的 fetchQuota 結果不該覆寫新家庭的 quota（新家庭根本沒查過）")
        XCTAssertEqual(store.quotaState, .idle)
        XCTAssertEqual(store.myFamily?.id, otherFamilyID, "新家庭本身應該正常更新，不受這條防線影響")
    }
}
