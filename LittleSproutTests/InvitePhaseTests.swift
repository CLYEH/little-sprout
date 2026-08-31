import Foundation
@testable import LittleSprout
import XCTest

/// `InvitePhase` 的狀態計算（R2 N1，merge-review comment `9dfd1a9c`）：`InviteFamilyView` 抽出
/// 這份純值型別，才能在沒有 ViewInspector 的情況下單元測試釘住「查詢中／查詢失敗都不能顯示
/// 可按的產生鈕」這條核心防線（同 `AuthButtonsState`／`AuthButtonsStateTests` 的理由）。
final class InvitePhaseTests: XCTestCase {
    private func makeInvite(code: String = "K7M2FD") -> GeneratedInvite {
        GeneratedInvite(
            id: UUID(),
            code: code,
            role: .member,
            expiresAt: Date().addingTimeInterval(7 * 86400),
            maxUses: 5,
            usedCount: 0
        )
    }

    // MARK: - 優先序

    func test_createInviteSubmitting_isGenerating_regardlessOfLookupOrLatestInvite() {
        // R2 N1：使用者剛按下「產生／重新產生」時，不管查詢方是不是也在跑、不管
        // `latestInvite` 目前是什麼值（重新產生流程會在 revoke 成功後把它設 nil），都必須是
        // `.generating`——這是唯一會停用「產生」按鈕、顯示 loading 骨架的狀態。
        let phase = InvitePhase(
            lookupInviteState: .submitting,
            createInviteState: .submitting,
            latestInvite: makeInvite()
        )

        XCTAssertEqual(phase, .generating)
    }

    func test_latestInvitePresent_isGenerated_evenWhileLookupSucceeded() {
        let invite = makeInvite()
        let phase = InvitePhase(lookupInviteState: .success, createInviteState: .idle, latestInvite: invite)

        XCTAssertEqual(phase, .generated(invite))
    }

    // MARK: - R2 N1 核心：查詢中／查詢失敗不能落回「空」（那會顯示可按的產生鈕）

    func test_lookupSubmitting_noLatestInvite_isCheckingExisting_notEmpty() {
        let phase = InvitePhase(lookupInviteState: .submitting, createInviteState: .idle, latestInvite: nil)

        XCTAssertEqual(phase, .checkingExisting, "查詢中不知道這個家庭有沒有既有碼，不能落回 .empty（會顯示可按的產生鈕）")
    }

    func test_lookupFailed_noLatestInvite_isLookupFailed_notEmpty() {
        let error = AppError.network(message: "offline")
        let phase = InvitePhase(lookupInviteState: .failure(error), createInviteState: .idle, latestInvite: nil)

        XCTAssertEqual(phase, .lookupFailed(error), "查詢失敗一樣不知道有沒有既有碼，不能落回 .empty，只能重試")
    }

    func test_lookupSucceededWithNoInvite_isEmpty() {
        let phase = InvitePhase(lookupInviteState: .success, createInviteState: .idle, latestInvite: nil)

        XCTAssertEqual(phase, .empty, "查詢成功且確定沒有既有碼，才是唯一允許產生的狀態")
    }

    func test_lookupIdle_noLatestInvite_isEmpty() {
        // 沒有家庭時 `refreshLatestInvite` 提早 return、`lookupInviteState` 停在 `.idle`——
        // 這裡不該顯示「查詢中」或「查詢失敗」的殼。
        let phase = InvitePhase(lookupInviteState: .idle, createInviteState: .idle, latestInvite: nil)

        XCTAssertEqual(phase, .empty)
    }

    // MARK: - showsDestructiveSection：只有已經有碼可以撤銷時才有意義

    func test_showsDestructiveSection_onlyForGeneratingAndGenerated() {
        XCTAssertFalse(InvitePhase.empty.showsDestructiveSection)
        XCTAssertFalse(InvitePhase.checkingExisting.showsDestructiveSection)
        XCTAssertFalse(InvitePhase.lookupFailed(.network(message: "offline")).showsDestructiveSection)
        XCTAssertTrue(InvitePhase.generating.showsDestructiveSection)
        XCTAssertTrue(InvitePhase.generated(makeInvite()).showsDestructiveSection)
    }
}
