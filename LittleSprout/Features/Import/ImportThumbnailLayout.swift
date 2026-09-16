import SwiftUI

/// 群卡縮圖列的格數規則（`design/littlesprout.pen` LS-251 VR R4 comment `0750949e`
/// 「值得保留」第 2 條：「iPad 群卡的 6 格規則——Row1 固定 3／Row2 0–3／≤6 不放 More
/// Cell／>6 才 More 且 N≥1」）。iPhone 的 3 格單列（MN-19 讀回值：`hX90D`/`z8da9e` 等卡皆
/// 縮圖 2＋More，即 3 格中 2 格縮圖＋1 格 More）是同一條規則在 `maxSlots=3` 下的特例——本型別
/// 把兩者收成同一條公式：`maxSlots` 格中，張數 ≤ `maxSlots` 全部放縮圖、不放 More Cell；
/// 超過則放 `maxSlots - 1` 張縮圖＋1 顆 More Cell（`N = 張數 - (maxSlots - 1)`，恆 ≥1，
/// R4 MN-19「全稿『+0』歸零」不會在這個公式下發生，因為只有超過門檻才會顯示 More Cell）。
enum ImportThumbnailLayout {
    /// iPhone 群卡內容區單列 3 格（LS-251 R3 MN-16：96.33pt 縮圖 fill_container 3 格均分
    /// 305 內容寬）。
    static let compactMaxSlots = 3
    /// iPad 群卡左欄 2×3 格（Row1 固定 3／Row2 0–3，96×96，Left Col 304）。
    static let regularMaxSlots = 6

    static func visibleThumbnailCount(assetCount: Int, maxSlots: Int) -> Int {
        assetCount <= maxSlots ? assetCount : maxSlots - 1
    }

    static func moreCount(assetCount: Int, maxSlots: Int) -> Int {
        assetCount <= maxSlots ? 0 : assetCount - (maxSlots - 1)
    }
}

/// 縮圖列本身——本票沒有時間做真的 `PHImageManager` 縮圖載入（見 handoff 風險段），每一格
/// 用系統圖示佔位（同 `PendingUpload.thumbnail` 系列既有慣例：來源解碼失敗時退回系統圖示，
/// 這裡是「本票範圍不含縮圖載入管線」的既知留白，畫面結構與點擊行為皆已到位）。
struct ImportThumbnailGridView: View {
    let assetCount: Int
    let maxSlots: Int
    var cellSize: CGFloat = 96

    private var visibleCount: Int {
        ImportThumbnailLayout.visibleThumbnailCount(assetCount: assetCount, maxSlots: maxSlots)
    }
    private var moreCount: Int {
        ImportThumbnailLayout.moreCount(assetCount: assetCount, maxSlots: maxSlots)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: AppSpacing.label), count: min(maxSlots, 3))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: AppSpacing.label) {
            ForEach(0..<visibleCount, id: \.self) { _ in thumbnailCell }
            if moreCount > 0 { moreCell }
        }
    }

    private var thumbnailCell: some View {
        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
            .fill(Color.lsSurface2)
            .frame(width: cellSize, height: cellSize)
            .overlay(
                Image(systemName: "photo")
                    .appIconFrame(.large)
                    .foregroundStyle(Color.lsTextSecondary)
            )
            .accessibilityHidden(true)
    }

    private var moreCell: some View {
        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
            .fill(Color.lsSurface2)
            .frame(width: cellSize, height: cellSize)
            .overlay(
                // `$fs-imprint`（12pt）刻意不吃 Dynamic Type，同 Typography.swift 檔頭文件
                // 註解——這是唯一不用 `appFont` 的字級。
                Text("+\(moreCount)").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.lsTextSecondary)
            )
            .accessibilityLabel("還有 \(moreCount) 張")
    }
}
