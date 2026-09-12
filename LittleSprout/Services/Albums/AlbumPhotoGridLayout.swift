import Foundation

/// LS-166（`design/littlesprout.pen` `LS-142 / 15 相簿詳情`）：相簿詳情瀑布流照片牆的放置
/// 規則——每格是「白邊＋四角托」的沖印品（`AlbumPhotoGridView.PrintCell`），不是
/// `MasonryPhotoWallView`（LS-126 日記詳情）那種無邊框縮圖，兩者欄寬公式雖然相同
/// （`MasonryLayout.columnCount` 的「欄寬 ≥164.5 可再加一欄」），但每一格的高度公式不同
/// （多了沖印品的白邊 padding），因此另建一支純函式，不直接重用 `MasonryLayout.place`。
///
/// Notes `kHDk4` `vfPjM`／`k3jJ5j`：iPhone 2 欄（colW 164.5，photoW 148.5）、iPad 3 欄
/// （colW 167，photoW 151）；欄內欄間 gap 皆 16；每格 padding `[8,8,32,8]`（上 8／右 8／
/// 下 32／左 8，`AppSpacing.printEdge`＝8，下緣 32 是刻意比一般沖印品 `printEdgeBottom`
/// （8）多出來的空白——這格沒有 Caption／Imprint Row，角托要落在沖印品最下緣，`cellHeight
/// = 8 + wrapH + 32` 才會讓角托 y（`printH − 21` 這條通式，`21 = 26(cornerSize) − 5
/// (cornerOut)`）落在 Notes 實測的 `wrapH + 19` 位置：`(8+wrapH+32) − 26 + 5 = wrapH + 19`，
/// 兩條式子互相印證，不是各自湊出來的巧合）。photoW 才是算比例高度的分母，不是 colW——
/// `wrapH = photoW / aspectRatio`（`aspectRatio` = 寬／高，4:3 橫式 ≈1.333、3:4 直式 0.75）。
enum AlbumPhotoGridLayout {
    /// 沖印品白邊：水平（左右）與上緣皆 `AppSpacing.printEdge`（8）；下緣刻意留白 32
    /// （見型別文件註解），不是 `AppSpacing.printEdgeBottom`（8，那個服務有 Caption 的沖印品）。
    static let photoPaddingHorizontal: CGFloat = AppSpacing.printEdge
    static let photoPaddingTop: CGFloat = AppSpacing.printEdge
    static let photoPaddingBottom: CGFloat = 32
    static let columnGap: CGFloat = 16
    static let minColumnWidth: CGFloat = 164.5

    /// 一次 `place` 呼叫的結果：`columns[i]` 是第 i 欄依序（由上而下）該放哪些原始索引
    /// （對應呼叫端 `photos` 陣列的 index）——刻意不回傳絕對座標（同 `MasonryLayout.
    /// Placement` 的 x/y），因為 SwiftUI 端直接用 `HStack{ForEach 欄}{VStack{ForEach 格}}`
    /// 渲染，不需要自己再疊一層絕對定位；欄內堆疊順序、格高皆由子視圖依 `columnWidth`／
    /// 各自的 `aspectRatio` 自然推導，不需要外部餵一個高度值進去。
    struct Result: Equatable {
        let columns: [[Int]]
        let columnWidth: CGFloat
    }

    /// 依「目前最矮的欄放下一張」貪婪演算法分組（同 `MasonryLayout.place` 的既有規則），
    /// 只回傳分組結果，不算高度——高度由 `photoHeight(forRatio:columnWidth:)` 現算，
    /// View 端每一格各自呼叫一次即可，不需要在這裡預先算好整份高度表。
    static func place(
        aspectRatios: [CGFloat], containerWidth: CGFloat,
        gap: CGFloat = columnGap, minColumnWidth: CGFloat = minColumnWidth
    ) -> Result {
        let columnCount = MasonryLayout.columnCount(forWidth: containerWidth, gap: gap, minColumnWidth: minColumnWidth)
        let columnWidth = columnCount > 0
            ? (containerWidth - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount) : containerWidth
        var columnHeights = [CGFloat](repeating: 0, count: columnCount)
        var columns: [[Int]] = Array(repeating: [], count: columnCount)
        for (index, ratio) in aspectRatios.enumerated() {
            var targetColumn = 0
            for column in 1..<columnCount where columnHeights[column] < columnHeights[targetColumn] {
                targetColumn = column
            }
            columns[targetColumn].append(index)
            columnHeights[targetColumn] += cellHeight(forRatio: ratio, columnWidth: columnWidth) + gap
        }
        return Result(columns: columns, columnWidth: columnWidth)
    }

    /// 沖印品內「照片」本身的寬度——扣掉左右白邊，View 端拿去 `.frame(width:height:)`
    /// 套用在圖片上。
    static func photoWidth(columnWidth: CGFloat) -> CGFloat {
        max(0, columnWidth - 2 * photoPaddingHorizontal)
    }

    /// 「照片」本身的高度（不含白邊）——`aspectRatio <= 0`（理論上不會發生，`MediaContent
    /// .aspectRatio` 已對這個情況退回 1，這裡是不依賴單一呼叫端的第二層防禦）一律當 1
    /// （正方形）處理，避免除以 0／負值產生的高度炸開版面。
    static func photoHeight(forRatio ratio: CGFloat, columnWidth: CGFloat) -> CGFloat {
        let safeRatio = ratio > 0 ? ratio : 1
        return photoWidth(columnWidth: columnWidth) / safeRatio
    }

    /// 整格（含白邊）的高度——`cellH = 8 + wrapH + 32`（型別文件註解），供 `place` 內部貪婪
    /// 演算法比較欄高用。
    static func cellHeight(forRatio ratio: CGFloat, columnWidth: CGFloat) -> CGFloat {
        photoPaddingTop + photoHeight(forRatio: ratio, columnWidth: columnWidth) + photoPaddingBottom
    }
}
