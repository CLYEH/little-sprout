@testable import LittleSprout
import SwiftUI
import UIKit
import XCTest

/// LS-405（LS-390 修復輪 handoff `94980f23`）：相簿 tab 卡（`AlbumSummaryCardView`）封面**載入後**不得把卡片撐寬。
/// 與 `AlbumCardCoverWidthTests`（時間軸 `PrintPhotoCard`）同一根因假設：`photo` 把 `scaledToFill` 影像直接放進
/// `ZStack { … }.frame(height:)`，寬幅照片蓋滿後 `ZStack` 取最大子視圖 → 卡片被撐寬。
///
/// 量法同 `AlbumCardCoverWidthTests`：`ImageRenderer` 把整張卡畫在綠底上，照片列第一個／最後一個非綠像素＝紙左右緣。
/// 「載入完成」以 `coverImage` 注入（`AsyncImage` 在單元測試宿主載不起來）。`photoCount: 8` 只有 1 片扇影，
/// 扇影在照片列之上，不影響照片列量測。
@MainActor
final class AlbumSummaryCardCoverWidthTests: XCTestCase {
    private static let scale: CGFloat = 3
    /// iPhone 17 Pro 402pt 扣兩側 `screenPad`。
    private static let cardWidth: CGFloat = 402 - 2 * AppSpacing.screenPad
    private static let margin: CGFloat = 60
    private static let photoHeight: CGFloat = 184

    func test_paperWidth_sameBeforeAndAfterWideCoverLoads() throws {
        let placeholder = try measure(cover: nil, scheme: .light)
        XCTAssertEqual(placeholder, Self.cardWidth, accuracy: 0.5, "占位圖時紙寬應＝欄寬")
        for scheme in [ColorScheme.light, .dark] {
            for (name, aspect) in [("1.85:1", 1.85), ("2:1", 2.0), ("5:1", 5.0)] {
                let loaded = try measure(cover: Self.solidImage(aspect: aspect), scheme: scheme)
                XCTAssertEqual(
                    loaded, placeholder, accuracy: 0.5,
                    "[\(scheme) \(name)] 封面載入後紙寬 \(loaded)pt ≠ 占位圖 \(placeholder)pt——封面照片撐寬了相簿 tab 卡"
                )
            }
        }
    }

    /// 修法沒有改動不溢出情境：直式（不會撐寬）與占位圖同版面。
    func test_portraitCover_sameWidthAsPlaceholder() throws {
        let placeholder = try measure(cover: nil, scheme: .light)
        let portrait = try measure(cover: Self.solidImage(aspect: 0.66), scheme: .light)
        XCTAssertEqual(portrait, placeholder, accuracy: 0.5)
    }

    // MARK: - helpers

    /// 回傳照片列的紙寬（pt）。
    private func measure(cover: Image?, scheme: ColorScheme) throws -> CGFloat {
        let card = AlbumSummaryCardView(
            album: AlbumSummary(
                id: UUID(), title: "2026 夏天的海邊", photoCount: 8, cover: nil, childIds: [], createdAt: Date()
            ),
            taggedChildren: [],
            cardWidth: Self.cardWidth,
            photoHeight: Self.photoHeight,
            coverImage: cover
        )
        let content = card
            .frame(width: Self.cardWidth)
            .padding(Self.margin)
            .background(Color(red: 0, green: 1, blue: 0))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.scale
        let pixels = try SRGBPixels(try XCTUnwrap(renderer.cgImage, "ImageRenderer 沒有產出影像"))

        func isGreen(_ column: Int, _ row: Int) -> Bool {
            let value = pixels.rgb(column: column, row: row)
            return value.y > 200 && value.x < 60 && value.z < 60
        }
        let photoRow = Int((Self.margin + AppSpacing.printEdge + Self.photoHeight / 2) * Self.scale)
        let columns = 0..<pixels.width
        let left = try XCTUnwrap(columns.first { !isGreen($0, photoRow) }, "照片列找不到紙左緣")
        let right = try XCTUnwrap(columns.last { !isGreen($0, photoRow) }, "照片列找不到紙右緣")
        return CGFloat(right - left + 1) / Self.scale
    }

    private static func solidImage(aspect: CGFloat) -> Image {
        let size = CGSize(width: 1000 * aspect, height: 1000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return Image(uiImage: image)
    }
}
