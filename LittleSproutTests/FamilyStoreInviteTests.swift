import Foundation
@testable import LittleSprout
import os
import XCTest

/// `FamilyStore` 換使用者（R1 F1 `syncOwner`／`reset`）與邀請碼生命週期（R1 F2 先刪後建、
/// R1 F4 `refreshLatestInvite`）——查詢我的家庭／建立家庭的基本狀態機測試在
/// `FamilyStoreTests`，純粹是 SwiftLint `type_body_length`（250 行）撞到才拆檔，兩者共用
/// 同一份 `StubFamilyAPIClient`（同 `SupabaseFamilyAPIClientJoinTests` 的拆檔理由）。
@MainActor
final class FamilyStoreInviteTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeFamily(id: UUID? = nil, name: String = "陳家") -> Family {
        Family(id: id ?? familyID, name: name, createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    private func makeInviteRecord(
        id: UUID = UUID(),
        code: String = "K7M2FD",
        role: FamilyRole = .member,
        maxUses: Int = FamilyStore.defaultInviteMaxUses,
        usedCount: Int = 0,
        expiresAt: Date = Date().addingTimeInterval(7 * 86400)
    ) -> InviteRecord {
        InviteRecord(id: id, code: code, role: role, maxUses: maxUses, usedCount: usedCount, expiresAt: expiresAt)
    }

    // MARK: - syncOwner／reset（R1 F1：換使用者或登出必須整份歸零，不能沿用前一位的資料）

    func test_syncOwner_differentUser_resetsStateAndRefetchesFamily() async {
        let stub = StubFamilyAPIClient()
        let familyA = makeFamily(name: "陳家")
        let familyB = makeFamily(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "林家")
        let userA = UUID()
        let userB = UUID()
        let currentFamily = OSAllocatedUnfairLock<Family?>(initialState: familyA)
        stub.setFetchMyFamilyHandler { currentFamily.withLock { $0 } }
        let record = makeInviteRecord(code: "AAAA11")
        stub.setCreateInviteHandler { _, _, _, _ in record }
        let store = FamilyStore(apiClient: stub)

        _ = await store.syncOwner(to: userA)
        _ = await store.createInvite(role: .member)
        XCTAssertEqual(store.myFamily, familyA)
        XCTAssertNotNil(store.latestInvite, "前置條件：A 已經產生過邀請碼")

        currentFamily.withLock { $0 = familyB }
        _ = await store.syncOwner(to: userB)

        XCTAssertEqual(store.myFamily, familyB, "換使用者後必須重新查詢 B 的家庭，不能沿用 A 的")
        XCTAssertNil(store.latestInvite, "B 不該看到 A 產生的邀請碼（R1 F1 具體失敗情境）")
        XCTAssertEqual(store.lookupState, .success)
    }

    func test_syncOwner_toNil_resetsStateWithoutFetching() async {
        // 登出：session 變 nil，不該再打一次查詢——沒有使用者可查。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        let userA = UUID()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setFetchMyFamilyHandler {
            callCount.withLock { $0 += 1 }
            return family
        }
        let store = FamilyStore(apiClient: stub)
        _ = await store.syncOwner(to: userA)
        XCTAssertEqual(store.myFamily, family)

        _ = await store.syncOwner(to: nil)

        XCTAssertNil(store.myFamily, "登出後必須清空，不能讓下一位使用者看到殘留的家庭")
        XCTAssertEqual(store.lookupState, .idle)
        XCTAssertEqual(callCount.withLock { $0 }, 1, "登出不該再打一次查詢")
    }

    func test_syncOwner_sameUser_doesNotRefetch() async {
        // scenePhase 之類觸發的重繪不該白白重打一次網路。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        let userA = UUID()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setFetchMyFamilyHandler {
            callCount.withLock { $0 += 1 }
            return family
        }
        let store = FamilyStore(apiClient: stub)

        _ = await store.syncOwner(to: userA)
        _ = await store.syncOwner(to: userA)

        XCTAssertEqual(callCount.withLock { $0 }, 1, "同一位使用者的重繪不該白白重打一次網路")
    }

    // MARK: - createInvite（07 邀請家人）

    func test_createInvite_success_setsLatestInviteAndSuccessState() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        let record = makeInviteRecord()
        stub.setCreateInviteHandler { _, _, _, _ in record }

        let code = await store.createInvite(role: .member)

        XCTAssertEqual(code, "K7M2FD")
        XCTAssertEqual(store.latestInvite?.code, "K7M2FD")
        XCTAssertEqual(store.latestInvite?.role, .member)
        XCTAssertEqual(store.latestInvite?.maxUses, FamilyStore.defaultInviteMaxUses)
        XCTAssertEqual(store.createInviteState, .success)
        // 07 沒有 UI 讓使用者自訂期限與次數——固定用既定決策（7 天／5 次）。
        XCTAssertEqual(stub.createInviteCalls.last?.maxUses, FamilyStore.defaultInviteMaxUses)
    }

    func test_createInvite_withoutFamily_failsWithoutCallingAPI() async {
        // 呼叫端自己組錯前置條件（沒有家庭卻想建邀請碼），不對應任何後端錯誤碼——不該真的打
        // 一次網路才發現這件事。
        let stub = StubFamilyAPIClient()
        stub.setCreateInviteHandler { _, _, _, _ in
            XCTFail("沒有家庭時不該呼叫 createInvite")
            throw StubFamilyAPIClient.StubError.unconfigured
        }
        let store = FamilyStore(apiClient: stub)

        let code = await store.createInvite(role: .member)

        XCTAssertNil(code)
        guard case .failure = store.createInviteState else {
            return XCTFail("沒有家庭應該落在 .failure，實際是 \(store.createInviteState)")
        }
    }

    func test_createInvite_generationCollision_mapsToRetryableSystemTier() async {
        // LS016（邀請碼產生連續撞碼）：`AppError.LSErrorCode.tier` 定案歸 `retryableSystem`
        // （見 `AppError.swift`），跟「換個輸入」的 validationRetryable 不同層——這裡驗證
        // `FamilyStore` 原封不動把已經歸好層的錯誤存進 `createInviteState`，UI 才能依層級
        // 挑對文案（「請再試一次」而不是「檢查輸入」）。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        stub.setCreateInviteHandler { _, _, _, _ in
            throw AppError.retryableSystem(message: "請再試一次", code: "LS016")
        }

        let code = await store.createInvite(role: .member)

        XCTAssertNil(code)
        XCTAssertEqual(store.createInviteState, .failure(.retryableSystem(message: "請再試一次", code: "LS016")))
    }

    // MARK: - createInvite「先刪後建」（R1 F2：重新產生必須先撤銷舊碼）

    func test_createInvite_whenLatestInviteExists_revokesOldBeforeCreatingNew() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        let oldRecord = makeInviteRecord(code: "OLD001")
        stub.setCreateInviteHandler { _, _, _, _ in oldRecord }
        _ = await store.createInvite(role: .member)
        guard let oldID = store.latestInvite?.id else {
            return XCTFail("前置條件：必須先有一支已產生的邀請碼")
        }

        stub.setRevokeInviteHandler { _ in }
        let newRecord = makeInviteRecord(code: "NEW002")
        stub.setCreateInviteHandler { _, _, _, _ in newRecord }

        let code = await store.createInvite(role: .member)

        XCTAssertEqual(code, "NEW002")
        XCTAssertEqual(store.latestInvite?.code, "NEW002", "重新產生後必須顯示新碼")
        XCTAssertEqual(stub.revokeInviteCalls, [oldID], "重新產生必須先撤銷舊碼那一列")
    }

    func test_createInvite_revokeFails_doesNotCreateNewCode() async {
        // 刪失敗不建：不能讓 owner 帳上同時存在一支「已經跟使用者說作廢、其實還活著」的舊碼
        // 與一支新碼（R1 F2）。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        let oldRecord = makeInviteRecord(code: "OLD001")
        stub.setCreateInviteHandler { _, _, _, _ in oldRecord }
        _ = await store.createInvite(role: .member)
        XCTAssertEqual(store.latestInvite?.code, "OLD001", "前置條件：必須先有一支已產生的邀請碼")

        stub.setRevokeInviteHandler { _ in throw AppError.network(message: "offline") }
        stub.setCreateInviteHandler { _, _, _, _ in
            XCTFail("撤銷失敗不該繼續呼叫 createInvite")
            throw StubFamilyAPIClient.StubError.unconfigured
        }

        let code = await store.createInvite(role: .member)

        XCTAssertNil(code)
        XCTAssertEqual(store.latestInvite?.code, "OLD001", "撤銷失敗時不該動到既有的邀請碼顯示")
        XCTAssertEqual(store.createInviteState, .failure(.network(message: "offline")))
    }

    // MARK: - refreshLatestInvite（R1 F4：07 進場先查既有有效邀請碼）

    func test_refreshLatestInvite_hasActiveInvite_setsLatestInvite() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        let record = makeInviteRecord(code: "EXIST1", usedCount: 2)
        stub.setFetchLatestActiveInviteHandler { _ in record }

        let invite = await store.refreshLatestInvite()

        XCTAssertEqual(invite?.code, "EXIST1")
        XCTAssertEqual(store.latestInvite?.code, "EXIST1")
        let expectedRemaining = FamilyStore.defaultInviteMaxUses - 2
        XCTAssertEqual(store.latestInvite?.remainingUses, expectedRemaining, "還可用次數必須是真實剩餘量，不是 maxUses")
    }

    func test_refreshLatestInvite_none_setsNil() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        stub.setFetchLatestActiveInviteHandler { _ in nil }

        let invite = await store.refreshLatestInvite()

        XCTAssertNil(invite)
        XCTAssertNil(store.latestInvite)
    }

    func test_resetCreateInviteState_clearsFailureOnly() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        stub.setCreateInviteHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        _ = await store.createInvite(role: .member)
        guard case .failure = store.createInviteState else {
            return XCTFail("前置條件失敗：預期先進入 .failure")
        }

        store.resetCreateInviteState()

        XCTAssertEqual(store.createInviteState, .idle)
    }
}
