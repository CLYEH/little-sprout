@testable import LittleSprout
import XCTest

/// LS-166 票文驗收：「尺寸公式單元測試與 Notes 一致」——斷值直接取自 `design/littlesprout.pen`
/// Notes `kHDk4` `vfPjM`／`k3jJ5j`（`pVSXP` 六格 Photo Wrap 高度）與 `rFiLJ`（iPad 欄寬）。
final class AlbumPhotoGridLayoutTests: XCTestCase {
    private let accuracy: CGFloat = 0.01

    // MARK: - 欄數／欄寬（沿用 MasonryLayout.columnCount，這裡只釘住實際餵進去的容器寬）

    func test_place_iPhoneContentWidth_uses2ColumnsAt164_5() {
        // 345 = 393（iPhone 標準寬）− 2×24（screenPad）。
        let result = AlbumPhotoGridLayout.place(aspectRatios: [1, 1], containerWidth: 345)
        XCTAssertEqual(result.columns.count, 2)
        XCTAssertEqual(result.columnWidth, 164.5, accuracy: accuracy)
    }

    func test_place_iPadContentPaneWidth_uses3ColumnsAt167() {
        // 533 = 834（iPad 11" 寬）− 220（Nav Sidebar）− 1（Divider）− 2×40（screenPadLarge）。
        let result = AlbumPhotoGridLayout.place(aspectRatios: [1, 1, 1], containerWidth: 533)
        XCTAssertEqual(result.columns.count, 3)
        XCTAssertEqual(result.columnWidth, 167, accuracy: accuracy)
    }

    // MARK: - photoWidth／photoHeight／cellHeight 對 Notes k3jJ5j 六格實測值

    func test_photoWidth_iPhoneColumnWidth164_5_is148_5() {
        XCTAssertEqual(AlbumPhotoGridLayout.photoWidth(columnWidth: 164.5), 148.5, accuracy: accuracy)
    }

    /// `SHn1L`：4:3 橫式（Notes 標「比例 1.333」，實際稿面樣本照片非精確 4/3 分數），分母
    /// photoW=148.5 → 111.5。148.5 / (4/3) = 111.375，與 Notes 實測 111.5 相差 0.125——
    /// 這組樣本圖片本身的實際像素比例不是精確的 4:3 分數（Notes 的「1.333」是三位小數近似
    /// 標記，不是斷言用的精確值），這裡放寬到 0.15 容忍度，仍遠小於「誤用 colW（164.5）當
    /// 分母」會產生的量級差異（164.5/1.333≈123.4，與 111.5 差 12），足以釘住公式本身用對了
    /// 分母。
    func test_photoHeight_ratio4to3_matchesNotesSHn1L() {
        let height = AlbumPhotoGridLayout.photoHeight(forRatio: 4.0 / 3.0, columnWidth: 164.5)
        XCTAssertEqual(height, 111.5, accuracy: 0.15)
    }

    /// `Uuum0`：1:1（比例 1.0）→ 148.5。
    func test_photoHeight_ratio1to1_matchesNotesUuum0() {
        let height = AlbumPhotoGridLayout.photoHeight(forRatio: 1.0, columnWidth: 164.5)
        XCTAssertEqual(height, 148.5, accuracy: accuracy)
    }

    /// `IS0DY`：3:4 直式（比例 0.75）→ 198。
    func test_photoHeight_ratio3to4_matchesNotesIS0DY() {
        let height = AlbumPhotoGridLayout.photoHeight(forRatio: 0.75, columnWidth: 164.5)
        XCTAssertEqual(height, 198, accuracy: 0.1)
    }

    /// `cellH = 8 + wrapH + 32`（型別文件註解）——與 Notes `piK2I`／票文 dispatch 原文的公式
    /// 逐字一致，用 1:1 這張（wrapH=148.5）驗證整數關係成立。
    func test_cellHeight_equals8PlusWrapHPlus32() {
        let wrapH = AlbumPhotoGridLayout.photoHeight(forRatio: 1.0, columnWidth: 164.5)
        let cellHeight = AlbumPhotoGridLayout.cellHeight(forRatio: 1.0, columnWidth: 164.5)
        XCTAssertEqual(cellHeight, 8 + wrapH + 32, accuracy: accuracy)
    }

    // MARK: - 貪婪分組（同 MasonryLayout 既有規則，這裡只驗證有套用在本型別上）

    func test_place_shortestColumnFirst_matchesGreedyRule() {
        // 兩張同比例（1:1）依序落兩欄；第三張兩欄打平應放左（欄 0）。
        let result = AlbumPhotoGridLayout.place(aspectRatios: [1, 1, 1], containerWidth: 345)
        XCTAssertEqual(result.columns[0], [0, 2])
        XCTAssertEqual(result.columns[1], [1])
    }

    func test_place_preservesOriginalOrderWithinColumn() {
        // 三張窄高比（0.5，直式，每張都很高）落同一欄的機率高——只斷言欄內索引遞增
        // （由上而下＝原始順序，不會被打散重排）。
        let result = AlbumPhotoGridLayout.place(aspectRatios: [0.5, 0.5, 0.5, 0.5], containerWidth: 345)
        for column in result.columns {
            XCTAssertEqual(column, column.sorted(), "同一欄內的索引必須維持遞增（原始加入順序）")
        }
    }

    func test_place_emptyInput_producesEmptyColumns() {
        let result = AlbumPhotoGridLayout.place(aspectRatios: [], containerWidth: 345)
        XCTAssertTrue(result.columns.allSatisfy(\.isEmpty))
    }

    func test_photoHeight_invalidRatio_fallsBackToSquare() {
        // 防禦性：0 或負的寬高比不應該讓高度變成 infinity／負值（同 MasonryLayout 既有防禦）。
        XCTAssertEqual(
            AlbumPhotoGridLayout.photoHeight(forRatio: 0, columnWidth: 164.5),
            AlbumPhotoGridLayout.photoHeight(forRatio: 1, columnWidth: 164.5), accuracy: accuracy
        )
        let height = AlbumPhotoGridLayout.photoHeight(forRatio: -1, columnWidth: 164.5)
        XCTAssertTrue(height.isFinite && height > 0)
    }
}
