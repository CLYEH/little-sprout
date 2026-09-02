import Foundation

/// 日記詳情瀑布流照片牆的放置規則（LS-126 票文 Scope 2）——純函式，不依賴 SwiftUI，方便用
/// 固定比例序列斷言欄高序列（見 `MasonryLayoutTests`）。
///
/// 規則：
///   - 欄數：「欄寬 ≥164.5 可再加一欄」——iPhone 內容寬 345（393 − 2×`screenPad` 24）在
///     這條規則下算出來剛好是 2 欄（見 `columnCount(forWidth:)` 文件），iPad 詳情左欄
///     360pt 同一條規則也算出 2 欄，跟票文「iPhone 2 欄」「iPad 左欄 360pt → 2 欄」兩個
///     已知結果一致，不是分開兩條規則湊出來的。
///   - 每張等比縮到欄寬，不裁切；依原始順序放進「目前最矮的欄」，欄高相等時放左邊
///     （index 較小的欄）。
///   - 刪除／重排後呼叫端對新的 `aspectRatios` 陣列整組重新呼叫 `place`（非增量）——
///     這個型別本身沒有「更新既有版面」的 API，設計上就是每次都重算。
enum MasonryLayout {
    struct Placement: Equatable {
        let column: Int
        let originX: CGFloat
        let originY: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// `place(aspectRatios:containerWidth:gap:minColumnWidth:)` 的回傳值——獨立命名型別
    /// 而不是 tuple：SwiftLint `large_tuple` 只准 2 個成員，這裡有 3 個。
    struct Result: Equatable {
        /// 與傳入的 `aspectRatios` 同序、同長度。
        let placements: [Placement]
        /// 容器該給多高，供外層 `.frame(height:)` 用。
        let contentHeight: CGFloat
        /// 供呼叫端決定要不要另外顯示欄數。
        let columnCount: Int
    }

    /// 「欄寬 ≥164.5 可再加一欄」推導出的封閉解：對 n 欄，欄寬＝(width − (n−1)×gap)／n；
    /// 要求欄寬 ≥ minColumnWidth 解出 n ≤ (width + gap) / (gap + minColumnWidth)，取最大
    /// 整數，下限 1 欄（不會有 0 欄）。`epsilon` 只是防浮點誤差把剛好落在門檻上的寬度
    /// （例如 345pt 算出來剛好 2.0）誤判成上一欄。
    static func columnCount(forWidth width: CGFloat, gap: CGFloat = 16, minColumnWidth: CGFloat = 164.5) -> Int {
        guard width > 0 else { return 1 }
        let epsilon: CGFloat = 1e-6
        let raw = (width + gap) / (gap + minColumnWidth)
        return max(1, Int((raw + epsilon).rounded(.down)))
    }

    private static func columnWidth(forWidth width: CGFloat, columnCount: Int, gap: CGFloat = 16) -> CGFloat {
        guard columnCount > 0 else { return width }
        return (width - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount)
    }

    static func place(
        aspectRatios: [CGFloat], containerWidth: CGFloat, gap: CGFloat = 16, minColumnWidth: CGFloat = 164.5
    ) -> Result {
        let columns = columnCount(forWidth: containerWidth, gap: gap, minColumnWidth: minColumnWidth)
        let colWidth = columnWidth(forWidth: containerWidth, columnCount: columns, gap: gap)
        var columnHeights = [CGFloat](repeating: 0, count: columns)
        var placements: [Placement] = []
        placements.reserveCapacity(aspectRatios.count)

        for ratio in aspectRatios {
            let safeRatio = ratio > 0 ? ratio : 1
            let itemHeight = colWidth / safeRatio
            var targetColumn = 0
            for column in 1..<columns where columnHeights[column] < columnHeights[targetColumn] {
                targetColumn = column
            }
            let originY = columnHeights[targetColumn]
            let originX = CGFloat(targetColumn) * (colWidth + gap)
            placements.append(
                Placement(column: targetColumn, originX: originX, originY: originY, width: colWidth, height: itemHeight)
            )
            columnHeights[targetColumn] = originY + itemHeight + gap
        }

        let contentHeight = max((columnHeights.max() ?? 0) - gap, 0)
        return Result(placements: placements, contentHeight: contentHeight, columnCount: columns)
    }
}
