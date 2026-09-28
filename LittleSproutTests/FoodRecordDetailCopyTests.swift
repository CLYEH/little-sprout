import Foundation
@testable import LittleSprout
import XCTest

/// LS-381 記錄詳情 04 家族的純函式：權限三態（誰看到哪顆鈕）、日期章文字、角托規則、壓印行年齡、過敏原句。
///
/// 為什麼要鎖：
/// - 權限：顯示了按不動的鈕（非作者按編輯必得 42501、member 按刪除必得 42501）＝壞體驗；該顯示的沒顯示＝owner
///   無法清掉別人記錯的記錄。規則逐字來自 Notes `J8qvq5`＋`docs/API.md` §3／§4 的 RLS／RPC 門檻。
/// - 日期章：詳情一律帶年、不補零（Notes `vMFj3` MN-1），AX 明確兩行——用錯格式會跟格子／sheet 對不上。
/// - 角托：有照片才有、且只有對角兩顆（04 `B8krzV` Corner TL／BR；04b 零角托）。
final class FoodRecordDetailCopyTests: XCTestCase {
    private let myself = UUID()
    private let someoneElse = UUID()

    // MARK: - 權限三態

    private func actions(author: UUID?, viewer: UUID?, owner: Bool, canRecord: Bool) -> [FoodRecordDetailAction] {
        FoodRecordDetailCopy.actions(
            authorID: author, currentUserID: viewer, isFamilyOwner: owner, canRecord: canRecord
        )
    }

    func test_actions_authorWhoCanRecord_seesEditOnly() {
        XCTAssertEqual(
            actions(author: myself, viewer: myself, owner: false, canRecord: true),
            [.edit], "作者（member）：只有編輯；刪除入口在 03b sheet 內"
        )
        XCTAssertEqual(
            actions(author: myself, viewer: myself, owner: true, canRecord: true),
            [.edit], "作者同時是 owner：仍只有編輯（04 稿面只畫編輯鈕）"
        )
    }

    func test_actions_nonAuthorOwner_seesDeleteOnly() {
        XCTAssertEqual(
            actions(author: someoneElse, viewer: myself, owner: true, canRecord: true),
            [.delete], "04c：非作者 owner 只有刪除（delete_child_food_record 放行 owner；upsert 不放行非作者）"
        )
        XCTAssertEqual(
            actions(author: nil, viewer: myself, owner: true, canRecord: true),
            [.delete], "作者已刪帳（author_id null）視為「不是我」"
        )
    }

    func test_actions_nonAuthorMemberAndViewer_seeNothing() {
        XCTAssertEqual(
            actions(author: someoneElse, viewer: myself, owner: false, canRecord: true),
            [], "非作者 member：不顯示任何動作"
        )
        XCTAssertEqual(
            actions(author: someoneElse, viewer: myself, owner: false, canRecord: false),
            [], "viewer：唯讀"
        )
        XCTAssertEqual(
            actions(author: myself, viewer: nil, owner: false, canRecord: true),
            [], "登入者身分未知：保守視為不是作者"
        )
    }

    func test_actions_authorDemotedToViewer_seesNothing() {
        XCTAssertEqual(
            actions(author: myself, viewer: myself, owner: false, canRecord: false),
            [], "child_food_records_update 要求作者仍是 owner/member——被降為 viewer 後按編輯必得 42501"
        )
    }

    // MARK: - 日期章

    func test_stampText_singleLineWithYearAndNoZeroPadding() throws {
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-06-08"))
        XCTAssertEqual(FoodRecordDetailCopy.stampText(firstTriedOn: date, twoLines: false), "2026年6月8日 第一次吃到")
    }

    func test_stampText_accessibilityLayoutBreaksExplicitlyAfterDate() throws {
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2025-11-18"))
        XCTAssertEqual(FoodRecordDetailCopy.stampText(firstTriedOn: date, twoLines: true), "2025年11月18日\n第一次吃到")
    }

    // MARK: - 角托

    func test_corners_diagonalPairOnlyWhenThereIsAPhoto() {
        XCTAssertEqual(FoodRecordPrint.corners(hasPhoto: true), [.topLeading, .bottomTrailing], "04：對角兩顆")
        XCTAssertEqual(FoodRecordPrint.corners(hasPhoto: false), [], "04b 空白沖印品：零角托")
    }

    // MARK: - 壓印行、記錄者、反應

    func test_imprintCaption_ageOnFirstTriedDayWithHardenedCharacters() throws {
        let child = Child(
            id: UUID(), name: "小安", birthday: try XCTUnwrap(BirthdayFormat.date(fromWireString: "2025-04-20")),
            avatarURL: nil, deletedAt: nil, createdAt: Date()
        )
        let bread = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-06-08"))
        let pumpkin = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2025-11-18"))
        XCTAssertEqual(
            FoodRecordDetailCopy.imprintCaption(child: child, firstTriedOn: bread),
            "小安 ·\u{00A0}1\u{00A0}歲\u{00A0}1\u{00A0}個\u{2060}月", "稿 `Iaasq` 逐字：年齡是第一次吃那天、不是今天"
        )
        XCTAssertEqual(
            FoodRecordDetailCopy.imprintCaption(child: child, firstTriedOn: pumpkin),
            "小安 ·\u{00A0}6\u{00A0}個\u{2060}月\u{2060}大", "稿 `bQhiX` 逐字"
        )
    }

    func test_recordedByAndAddPhotoLabel() {
        XCTAssertEqual(FoodRecordDetailCopy.recordedBy(displayName: "媽媽"), "媽媽記錄")
        XCTAssertEqual(FoodRecordDetailCopy.addPhotoLabel(foodName: "南瓜"), "加一張第一次吃南瓜的照片")
    }

    func test_reactionLabel_threeValuesAndHidesUnknown() {
        XCTAssertEqual(FoodRecordDetailCopy.reaction("liked")?.label, "喜歡")
        XCTAssertEqual(FoodRecordDetailCopy.reaction("neutral")?.label, "普通")
        XCTAssertEqual(FoodRecordDetailCopy.reaction("disliked")?.label, "不愛吃")
        XCTAssertNil(FoodRecordDetailCopy.reaction(nil), "沒選反應：chip 隱藏")
        XCTAssertNil(FoodRecordDetailCopy.reaction("love"), "CHECK 之外的值不把英文代碼露出來")
    }

    // MARK: - 過敏原 info 句

    func test_allergenSentence_wheatUsesLongNameVerbatim() {
        XCTAssertEqual(
            FoodRecordDetailCopy.allergenSentence(["wheat"]),
            "含麩質（小麥、燕麥等穀物），是常見過敏原。只是提醒，不是醫療建議；有疑問請問醫師。", "稿 `dl1RU` 逐字"
        )
    }

    func test_allergenSentence_listsEveryAllergenAndHidesWhenNone() {
        XCTAssertEqual(
            FoodRecordDetailCopy.allergenSentence(["milk", "egg"]),
            "含牛奶、蛋，是常見過敏原。只是提醒，不是醫療建議；有疑問請問醫師。", "多種時逐項列出（不像格子只寫「等」）"
        )
        XCTAssertNil(FoodRecordDetailCopy.allergenSentence([]), "沒有過敏原整列隱藏（04b 南瓜）")
    }
}
