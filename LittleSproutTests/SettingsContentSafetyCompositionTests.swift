import XCTest
@testable import LittleSprout

/// LS-188 票文驗收：「XCTest（區塊組成依角色 Owner／成員）」——「內容與安全」區塊的
/// 「檢舉紀錄」列只有 Owner 看得到（稿面：檢舉收件匣僅 Owner 可見），這裡鎖住的是判斷本身，
/// 不必真的渲染 `SettingsView`（`SettingsRowView`／`SettingsCard` 這些 UI 組裝——`UITests
/// /SettingsViewTests.swift` 另外覆蓋 owner／member 兩種視角的實際渲染結果）。
final class SettingsContentSafetyCompositionTests: XCTestCase {
    func testOwner_includesReportInboxBetweenBlockListAndStorage() {
        XCTAssertEqual(
            SettingsContentSafetyComposition.rows(isOwner: true),
            [.blockList, .reportInbox, .storage]
        )
    }

    func testMember_excludesReportInbox() {
        XCTAssertEqual(
            SettingsContentSafetyComposition.rows(isOwner: false),
            [.blockList, .storage]
        )
    }
}
