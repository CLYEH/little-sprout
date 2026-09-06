import Foundation
@testable import LittleSprout
import XCTest

/// LS-189：`ReportReason`（p_reason → key 對照表，LS-152 Notes MN-7）與 `ContentTargetType`
/// 顯示屬性——純資料窮舉，同 `FamilyMemberActionVisibilityTests.
/// test_membersListDisplayLabel_owner_isFamilyManagerNotOwner` 既有慣例。
final class SafetyModelsTests: XCTestCase {
    // MARK: - ReportReason（p_reason → key 對照表，Notes `b28VzO`）

    func test_reportReason_rawValues_matchBackendContract() {
        // report_content 送出的是 rawValue（ASCII key），後端／Dashboard 分類統計依賴這組字面值
        // 穩定不變——改了任何一個 rawValue 都是破壞性變更。
        XCTAssertEqual(ReportReason.sexual.rawValue, "sexual")
        XCTAssertEqual(ReportReason.harassment.rawValue, "harassment")
        XCTAssertEqual(ReportReason.hate.rawValue, "hate")
        XCTAssertEqual(ReportReason.privacy.rawValue, "privacy")
        XCTAssertEqual(ReportReason.spam.rawValue, "spam")
        XCTAssertEqual(ReportReason.other.rawValue, "other")
    }

    func test_reportReason_displayLabel_matchesDesignBoard() {
        // 稿面 `SSfdn`／`q4mb2` 六個 Label 節點文字逐字比對。
        XCTAssertEqual(ReportReason.sexual.displayLabel, "色情或猥褻內容")
        XCTAssertEqual(ReportReason.harassment.displayLabel, "騷擾、霸凌或恐嚇")
        XCTAssertEqual(ReportReason.hate.displayLabel, "歧視或仇恨言論")
        XCTAssertEqual(ReportReason.privacy.displayLabel, "侵害隱私或未經同意的內容")
        XCTAssertEqual(ReportReason.spam.displayLabel, "詐騙或垃圾訊息")
        XCTAssertEqual(ReportReason.other.displayLabel, "其他")
    }

    func test_reportReason_allCases_hasExactlySixInOrder() {
        // 稿面 `f0seZg`／`ibL9M` Reason List 六列固定順序——`ReportReasonSheet` 用
        // `ReportReason.allCases` 直接畫列，順序跑掉會讓 UI 跟著錯位。
        XCTAssertEqual(
            ReportReason.allCases, [.sexual, .harassment, .hate, .privacy, .spam, .other]
        )
    }

    // MARK: - ContentTargetType 顯示屬性（檢舉收件匣卡片用）

    func test_contentTargetType_displayLabel() {
        XCTAssertEqual(ContentTargetType.diary.displayLabel, "日記")
        XCTAssertEqual(ContentTargetType.album.displayLabel, "相簿")
        XCTAssertEqual(ContentTargetType.media.displayLabel, "照片")
        XCTAssertEqual(ContentTargetType.comment.displayLabel, "留言")
    }

    func test_contentTargetType_icon_matchesDesignBoardForDemoedTypes() {
        // 稿面 `J5sQHy` 只示範了留言／照片兩種卡片，這兩個值逐字對稿；日記／相簿無稿面依據，
        // 只驗證「有一個合理值」不逐字比對系統圖示字串（避免把未來可能微調的圖示名鎖死）。
        XCTAssertEqual(ContentTargetType.comment.icon, "message.fill")
        XCTAssertEqual(ContentTargetType.media.icon, "photo")
        XCTAssertFalse(ContentTargetType.diary.icon.isEmpty)
        XCTAssertFalse(ContentTargetType.album.icon.isEmpty)
    }

    // MARK: - ReportCardItem.reasonDisplayLabel（07 收件匣卡片：reason key → 中文對照，含防禦性兜底）

    func test_reportCardItem_reasonDisplayLabel_resolvesKnownKey() {
        let record = ContentReportRecord(
            id: UUID(), targetType: .comment, targetID: UUID(), reporterID: UUID(),
            reason: "harassment", status: "pending", createdAt: Date()
        )
        let item = ReportCardItem(report: record, reporterName: "李阿嬤", snippet: "測試內容")
        XCTAssertEqual(item.reasonDisplayLabel, "騷擾、霸凌或恐嚇")
    }

    /// 防禦性兜底：舊資料或非本 app 送出的自由文字（`report_content` 的 `p_reason` 是自由文字，
    /// 後端沒有 enum 約束，見 `docs/API.md` §4）解析失敗時顯示原始字串，不是空白或當機。
    func test_reportCardItem_reasonDisplayLabel_unknownKey_fallsBackToRawString() {
        let record = ContentReportRecord(
            id: UUID(), targetType: .comment, targetID: UUID(), reporterID: UUID(),
            reason: "some_legacy_free_text", status: "pending", createdAt: Date()
        )
        let item = ReportCardItem(report: record, reporterName: "李阿嬤", snippet: "測試內容")
        XCTAssertEqual(item.reasonDisplayLabel, "some_legacy_free_text")
    }
}
