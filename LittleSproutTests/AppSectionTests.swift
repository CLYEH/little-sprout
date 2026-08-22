import UIKit
import XCTest
@testable import LittleSprout

/// `AppSection` 是導航 selection 的單一來源，compact 的 TabView 與 regular 的
/// NavigationSplitView 都由它驅動。這些測試鎖住的是「導航長什麼樣」的意圖，
/// 所以任何人增刪區塊、改順序或改圖示時都會先被這裡擋下來。
final class AppSectionTests: XCTestCase {
    func testSectionsAndOrderMatchTheNavigationLayout() {
        XCTAssertEqual(
            AppSection.allCases,
            [.timeline, .albums, .children, .settings],
            "四個區塊與其順序同時決定 TabView 分頁順序與 sidebar 排序，改動需連同版面與設計稿一起確認"
        )
    }

    func testEverySectionHasANonEmptyTitle() {
        for section in AppSection.allCases {
            XCTAssertFalse(
                section.title.isEmpty,
                "\(section) 沒有標題，分頁與 sidebar 會出現無法辨識的空白項目"
            )
        }
    }

    func testEverySectionSymbolExistsInSFSymbols() {
        for section in AppSection.allCases {
            XCTAssertNotNil(
                UIImage(systemName: section.systemImage),
                "SF Symbol「\(section.systemImage)」不存在；系統會靜默回傳 nil，"
                    + "使用者看到的是沒有圖示的分頁而不是錯誤"
            )
        }
    }
}
