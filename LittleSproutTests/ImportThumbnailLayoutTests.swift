@testable import LittleSprout
import XCTest

/// LS-303 範圍 2／6：iPad 六格上限規則（`design/littlesprout.pen` LS-251 VR R4 comment
/// `0750949e`「Row1 固定 3／Row2 0–3／≤6 不放 More Cell／>6 才 More 且 N≥1」）與 iPhone
/// 3 格單列同一公式的兩個特例。
final class ImportThumbnailLayoutTests: XCTestCase {
    // MARK: - iPad maxSlots=6

    func test_regularMaxSlots_atOrBelowSix_showsAllThumbnailsNoMoreCell() {
        for count in 1...6 {
            XCTAssertEqual(
                ImportThumbnailLayout.visibleThumbnailCount(assetCount: count, maxSlots: 6), count,
                "count=\(count)"
            )
            XCTAssertEqual(ImportThumbnailLayout.moreCount(assetCount: count, maxSlots: 6), 0, "count=\(count)")
        }
    }

    func test_regularMaxSlots_sevenAssets_showsFiveThumbnailsPlusMoreTwo() {
        // R4 讀回值：36→23+8+5，02-iPad card2「7 張」5 縮圖＋「+2」。
        XCTAssertEqual(ImportThumbnailLayout.visibleThumbnailCount(assetCount: 7, maxSlots: 6), 5)
        XCTAssertEqual(ImportThumbnailLayout.moreCount(assetCount: 7, maxSlots: 6), 2)
    }

    func test_regularMaxSlots_twentyThreeAssets_showsFiveThumbnailsPlusMoreEighteen() {
        // R4 讀回值：01-iPad card1「23 張」5 縮圖＋「+18」。
        XCTAssertEqual(ImportThumbnailLayout.visibleThumbnailCount(assetCount: 23, maxSlots: 6), 5)
        XCTAssertEqual(ImportThumbnailLayout.moreCount(assetCount: 23, maxSlots: 6), 18)
    }

    // MARK: - iPhone maxSlots=3

    func test_compactMaxSlots_atOrBelowThree_showsAllThumbnailsNoMoreCell() {
        for count in 1...3 {
            XCTAssertEqual(
                ImportThumbnailLayout.visibleThumbnailCount(assetCount: count, maxSlots: 3), count,
                "count=\(count)"
            )
            XCTAssertEqual(ImportThumbnailLayout.moreCount(assetCount: count, maxSlots: 3), 0, "count=\(count)")
        }
    }

    func test_compactMaxSlots_fiveAssets_showsTwoThumbnailsPlusMoreThree() {
        // R4 讀回值：01 iPhone card2「5 張」縮圖 2＋More「+3」（2+3=5）。
        XCTAssertEqual(ImportThumbnailLayout.visibleThumbnailCount(assetCount: 5, maxSlots: 3), 2)
        XCTAssertEqual(ImportThumbnailLayout.moreCount(assetCount: 5, maxSlots: 3), 3)
    }

    func test_compactMaxSlots_twentyThreeAssets_showsTwoThumbnailsPlusMoreTwentyOne() {
        // R4 讀回值：01 iPhone card1「23 張」縮圖 2＋More「+21」（2+21=23）。
        XCTAssertEqual(ImportThumbnailLayout.visibleThumbnailCount(assetCount: 23, maxSlots: 3), 2)
        XCTAssertEqual(ImportThumbnailLayout.moreCount(assetCount: 23, maxSlots: 3), 21)
    }

    // MARK: - More Cell 永遠不會是 "+0"（R4 MN-19）

    func test_moreCount_neverZeroWhenShown() {
        for maxSlots in [3, 6] {
            for count in 0...30 {
                let more = ImportThumbnailLayout.moreCount(assetCount: count, maxSlots: maxSlots)
                if more != 0 { XCTAssertGreaterThan(more, 0, "maxSlots=\(maxSlots) count=\(count)") }
            }
        }
    }
}
