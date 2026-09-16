import Photos
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

/// 縮圖列本身——`ImportThumbnailCell` 透過 `provider`（`ImportThumbnailProvider`，可為
/// `nil`：harness／preview 沒有真的 `PHAsset` 時）載入真實縮圖（LS-303 R2，merge-review R1
/// M1）；找不到圖時退回系統圖示佔位（同 `PendingUpload.thumbnail` 系列既有慣例）。
///
/// merge-review R1 i5：欄寬改 `.flexible()`（原 `.fixed(96)`×3＋間距＝304pt 固定寬，
/// iPad 分割視窗／Slide Over 等 <393pt 寬容器會橫向溢出）——稿面 `mEakH` 本來就是
/// `fill_container` 均分，格子改用 `.aspectRatio(1, contentMode: .fit)` 撐成正方形，
/// 寬度隨容器縮放，`cellSize` 只當縮圖請求解析度的提示值、不再是版面寫死寬度。
struct ImportThumbnailGridView: View {
    let assetIDs: [String]
    let maxSlots: Int
    let provider: ImportThumbnailProvider?
    var cellSize: CGFloat = 96

    private var visibleIDs: ArraySlice<String> {
        let count = ImportThumbnailLayout.visibleThumbnailCount(assetCount: assetIDs.count, maxSlots: maxSlots)
        return assetIDs.prefix(count)
    }
    private var moreCount: Int {
        ImportThumbnailLayout.moreCount(assetCount: assetIDs.count, maxSlots: maxSlots)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AppSpacing.label), count: min(maxSlots, 3))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: AppSpacing.label) {
            ForEach(visibleIDs, id: \.self) { assetID in
                ImportThumbnailCell(assetID: assetID, provider: provider, cellSize: cellSize)
            }
            if moreCount > 0 { ImportMoreCell(count: moreCount) }
        }
    }
}

/// 單一縮圖格——`task(id: assetID)` 在格子出現時發出一次請求，`onDisappear` 取消飛行中的
/// 請求（`PHImageRequestID`，捲動離開畫面時不必等一張看不到的圖載完）。
struct ImportThumbnailCell: View {
    let assetID: String
    let provider: ImportThumbnailProvider?
    var cellSize: CGFloat = 96

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
            .fill(Color.lsSurface2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                } else {
                    Image(systemName: "photo")
                        .appIconFrame(.large)
                        .foregroundStyle(Color.lsTextSecondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: assetID) {
                let target = CGSize(width: cellSize * displayScale, height: cellSize * displayScale)
                requestID = provider?.requestImage(for: assetID, targetSize: target) { loadedImage in
                    image = loadedImage
                }
            }
            .onDisappear {
                if let requestID { provider?.cancelRequest(requestID) }
            }
    }
}

private struct ImportMoreCell: View {
    let count: Int

    var body: some View {
        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
            .fill(Color.lsSurface2)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                // `$fs-imprint`（12pt）刻意不吃 Dynamic Type，同 Typography.swift 檔頭文件
                // 註解——這是唯一不用 `appFont` 的字級。
                Text("+\(count)").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.lsTextSecondary)
            )
            .accessibilityLabel("還有 \(count) 張")
    }
}
