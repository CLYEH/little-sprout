import Foundation
@testable import LittleSprout
import XCTest

/// LS-193：跟 `DeleteAccountFlowModelTests` 是同一個測試對象，拆成獨立檔案純粹是為了
/// SwiftLint `type_body_length`（同 `OTPVerificationModelLockoutTests.swift` 檔頭的既有理由）
/// ——共用該檔的 `makeModel(...)`／`waitUntil(...)` 測試工廠方法。
extension DeleteAccountFlowModelTests {
    // MARK: - in-flight guard（連點兩下不該送出兩次，見票文範圍 2「防重複送出」）

    func test_confirmDeletion_calledWhileProcessing_ignoresDuplicateCall() async {
        let stub = StubAccountAPIClient()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setDeleteMyAccountHandler {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return .success
        }
        stub.setFinalizeHandler {}
        let fixture = makeModel(accountAPIClient: stub, members: [makeMember(id: myID, role: .member)])

        fixture.model.confirmDeletion()
        let reachedInProgress = await waitUntil { fixture.model.step == .inProgress }
        guard reachedInProgress else {
            gateContinuation.finish()
            return XCTFail("等待進入 .inProgress 逾時（1 秒）")
        }

        fixture.model.confirmDeletion() // 應該被 isProcessing 擋下

        gateContinuation.finish()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待流程完成逾時（1 秒）")

        XCTAssertEqual(stub.deleteMyAccountCallCount, 1, "第二次呼叫應該被 isProcessing 擋下，底層 RPC 只該被呼叫一次")
    }

    // MARK: - classification 即時反映 FamilyStore 現況（不需要顯式「重新分流」呼叫）

    /// 取代舊版 `refreshClassificationIfNeeded()` 機制（R2 覆盤：改用即時計算屬性，見
    /// `DeleteAccountClassification` 文件註解）——這裡釘住「不需要任何顯式呼叫，`familyStore
    /// .members` 一變，`classification` 下次讀取就反映新值」這個核心行為（`FamilyStore` 是
    /// `@Observable`，SwiftUI 端會自然重繪，這裡直接讀計算屬性驗證資料面的正確性）。
    func test_classification_reflectsLiveFamilyStoreChangesWithoutExplicitRefresh() {
        let fixture = makeModel(members: [
            makeMember(id: myID, role: .owner), makeMember(id: otherID, role: .member)
        ])
        XCTAssertEqual(fixture.model.classification, .mustTransferOwnership(
            families: [FamilyPendingTransfer(familyID: fixture.familyStore.myFamily!.id, familyName: "陳家")]
        ))

        // 模擬「使用者去 FamilyMembersView 完成轉移」在同一個 familyStore 上就地更新的效果。
        fixture.familyStore.seedMembersForPreview([
            makeMember(id: myID, role: .member), makeMember(id: otherID, role: .owner)
        ])

        XCTAssertEqual(fixture.model.classification, .generalMember, "members 一變，classification 立刻反映，不需要重新分流")
    }

    /// 使用者已經往下走到 04e，`classification` 不應該影響 `step`——兩者是獨立的資訊來源
    /// （`step` 是流程進度，`classification` 只在 `step == nil` 時才被畫面拿來決定顯示哪張）。
    func test_step_unaffectedByClassificationChangesAfterProceedingToFinalConfirm() {
        let fixture = makeModel(members: [makeMember(id: myID, role: .member)])
        fixture.model.proceedToFinalConfirm(origin: .generalMember)
        XCTAssertEqual(fixture.model.step, .finalConfirm(origin: .generalMember))

        fixture.familyStore.seedMembersForPreview([makeMember(id: myID, role: .owner)])

        XCTAssertEqual(
            fixture.model.step, .finalConfirm(origin: .generalMember),
            "使用者已經往下走，familyStore 的背景變化不該把畫面拉回三分流"
        )
    }

    // MARK: - finishAndReturnToWelcome（04g：清 stores＋登出）

    func test_finishAndReturnToWelcome_resetsAllStoresAndClearsSession() async {
        let session = AuthSession(userID: myID, email: "a@example.com", expiresAt: .distantFuture)
        let authStub = StubAuthService(currentSession: session)
        let fixture = makeModel(members: [makeMember(id: myID, role: .member)], authStub: authStub)
        fixture.childrenStore.seedRoleForPreview(.member)
        fixture.timelineStore.seedForPreview(entries: [makeTimelineEntry()])
        fixture.albumsStore.seedForPreview(albums: [
            AlbumSummary(id: UUID(), title: "測試相簿", photoCount: 0, cover: nil, childIds: [], createdAt: Date())
        ])
        XCTAssertNotNil(fixture.authStore.session)
        XCTAssertNotNil(fixture.familyStore.myFamily)
        XCTAssertNotNil(fixture.childrenStore.myRole)
        XCTAssertFalse(fixture.timelineStore.entries.isEmpty)
        XCTAssertFalse(fixture.albumsStore.albums.isEmpty)
        XCTAssertTrue(fixture.eulaStore.isKnown(for: myID), "前置：fixture 種好 judgedUserID＝myID")

        await fixture.model.finishAndReturnToWelcome()

        XCTAssertNil(fixture.authStore.session)
        XCTAssertNil(fixture.familyStore.myFamily)
        XCTAssertNil(fixture.childrenStore.myRole)
        XCTAssertTrue(fixture.timelineStore.entries.isEmpty)
        XCTAssertTrue(fixture.albumsStore.albums.isEmpty)
        XCTAssertFalse(
            fixture.eulaStore.isKnown(for: myID),
            "eulaStore 也要歸零（同機換帳號不能沿用上一位使用者的 shouldPresent）"
        )
    }

    private func makeTimelineEntry() -> TimelineEntry {
        TimelineEntry(
            kind: .diary, refId: UUID(), occurredAt: Date(), childIds: [],
            content: .diary(DiaryContent(body: "測試日記", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0))
        )
    }
}
