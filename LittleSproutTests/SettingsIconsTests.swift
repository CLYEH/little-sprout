import UIKit
import XCTest
@testable import LittleSprout

/// LS-188：01 設定頁新用到的 SF Symbol 名稱防打錯字——同 `AppSectionTests
/// .testEverySectionSymbolExistsInSFSymbols` 的既有理由，符號名稱打錯時系統會靜默回傳 nil、
/// 畫面出現空白圖示而不是編譯錯誤或 runtime crash。這裡只做「存在與否」這道第一層防線
/// （不比照 `AppSectionTests` 加上 deployment target 版本表比對——那支測試涵蓋的是 tab bar
/// 這種每次啟動都會看到的常駐符號，這裡的符號分散在設定頁各列，風險與維護成本的取捨不同，
/// 記入 handoff「未完成」）。
///
/// `SettingsSection.icon`（iPad sidebar）與 `SettingsView`／`SettingsView+Profile.swift`
/// 各列圖示都是字面 SF Symbol 字串，沒有共用的列舉可以逐一列舉——這裡把兩邊用到的所有符號
/// 集中寫一份清單，跟著程式碼手動同步（新增列／換圖示時記得一起補這裡）。
final class SettingsIconsTests: XCTestCase {
    private static let allUsedSymbols: [String] = [
        // SettingsRowView 呼叫端（家庭／內容與安全／法律／帳號四區＋ProfileSummaryRow）。
        "person.2.fill", "person.badge.plus", "door.left.hand.open",
        "person.fill.xmark", "flag.fill", "internaldrive",
        "doc.text", "shield",
        "rectangle.portrait.and.arrow.right", "trash",
        "chevron.right",
        // ProfilePrintChip 占位相片圖示。
        "person.fill",
        // StorageUsageView 警示列圖示。
        "exclamationmark.circle.fill"
    ] + SettingsSection.allCases.map(\.icon)

    func testAllUsedSymbolsExistInSFSymbols() {
        for symbol in Self.allUsedSymbols {
            XCTAssertNotNil(
                UIImage(systemName: symbol),
                "SF Symbol「\(symbol)」不存在；系統會靜默回傳 nil，使用者看到的是空白圖示而不是錯誤"
            )
        }
    }
}
