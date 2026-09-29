@testable import LittleSprout
import SwiftUI
import UIKit
import XCTest

/// LS-390 R2（QA R1 FAIL）：時間軸相簿卡封面**載入後**，卡片被封面照撐寬、Caption 字起點偏離日記卡軸 4pt
/// （占位圖時只差 0.67pt）。UITest fixture 的 `cover: nil` 永遠量不到，所以這支專守「封面載入前後版面相同」。
///
/// 根因：`PrintPhotoCard.photo` 原本把 `image.resizable().scaledToFill()` 直接放進
/// `ZStack { … }.frame(height:)`。`scaledToFill` 蓋滿提案框、理想尺寸比提案框大——寬幅照片在 190pt 高蓋滿後
/// 寬度＝190×長寬比＞欄寬，`ZStack` 取最大子視圖，整張卡被撐寬；`VStack` 預設置中，Caption 列因此被帶偏
/// （QA 量到卡寬 +7、字起點 +3.3）。`.clipped()` 只裁繪製結果、不改 layout 回報。修法＝固定高度底色當本體、
/// 影像放 `overlay`。
///
/// 量法：`ImageRenderer` 把整張 `PrintPhotoCard`（帶 Caption 列）畫在綠底上，逐列掃：紙的左右緣＝照片列
/// 第一個／最後一個非綠像素，Caption 字起點＝Caption 帶內第一個深色像素離紙左緣的距離。「載入完成」以
/// `coverImage` 注入（`AsyncImage` 在單元測試宿主載不起來；三條照片路徑共用同一個照片窗容器）。
@MainActor
final class AlbumCardCoverWidthTests: XCTestCase {
    private static let scale: CGFloat = 3
    /// iPhone 17 Pro 402pt 扣兩側 `screenPad`。
    private static let cardWidth: CGFloat = 402 - 2 * AppSpacing.screenPad
    private static let margin: CGFloat = 60
    private static let photoHeight: CGFloat = 190

    func test_captionAxis_andPaperWidth_sameBeforeAndAfterWideCoverLoads() throws {
        for (name, aspect) in [("2:1", 2.0), ("QA 實測近似 1.85:1", 1.85), ("5:1", 5.0)] {
            let placeholder = try measure(cover: nil)
            let loaded = try measure(cover: Self.solidImage(aspect: aspect))
            XCTAssertEqual(placeholder.paperWidth, Self.cardWidth, accuracy: 0.5, "占位圖時紙寬應＝欄寬")
            XCTAssertEqual(
                loaded.paperWidth, placeholder.paperWidth, accuracy: 0.5,
                "[\(name)] 封面載入後紙寬 \(loaded.paperWidth)pt ≠ 占位圖 \(placeholder.paperWidth)pt——封面照片撐寬了卡片"
            )
            XCTAssertEqual(
                loaded.captionStartX, placeholder.captionStartX, accuracy: 1,
                "[\(name)] 封面載入後 Caption 字起點離紙左緣 \(loaded.captionStartX)pt，占位圖 \(placeholder.captionStartX)pt，"
                    + "差超過 1pt——與日記卡不同軸"
            )
        }
    }

    /// 修法沒有改動不溢出情境：直式（不會撐寬）與占位圖同版面。
    func test_portraitCover_sameLayoutAsPlaceholder() throws {
        let placeholder = try measure(cover: nil)
        let portrait = try measure(cover: Self.solidImage(aspect: 0.66))
        XCTAssertEqual(portrait.paperWidth, placeholder.paperWidth, accuracy: 0.5)
        XCTAssertEqual(portrait.captionStartX, placeholder.captionStartX, accuracy: 0.5)
    }

    // MARK: - helpers

    private struct Measurement {
        let paperWidth: CGFloat
        let captionStartX: CGFloat
    }

    private func measure(cover: Image?) throws -> Measurement {
        let card = PrintPhotoCard(
            photoHeight: Self.photoHeight, mountPoolOpacity: .card, showsImprint: false, coverImage: cover,
            imprintCaption: AnyView(
                Text("2026 夏天的海邊 · 8 張相片")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.lsPrintInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        )
        let content = card
            .frame(width: Self.cardWidth)
            .padding(Self.margin)
            .background(Color(red: 0, green: 1, blue: 0))
            .environment(\.colorScheme, .light)
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

        // Caption 帶：照片下緣（printEdge＋photo）之後 7 起、約一行高；避開角托（左緣內 15pt）。
        let bandTop = Int((Self.margin + AppSpacing.printEdge + Self.photoHeight + 7) * Self.scale)
        let bandBottom = bandTop + Int(20 * Self.scale)
        func isInk(_ column: Int, _ row: Int) -> Bool {
            let value = pixels.rgb(column: column, row: row)
            return value.x < 110 && value.y < 110 && value.z < 110
        }
        let searchStart = left + Int(15 * Self.scale)
        let inkColumn = try XCTUnwrap(
            (searchStart..<right).first { column in (bandTop..<bandBottom).contains { isInk(column, $0) } },
            "Caption 帶找不到墨色字形"
        )
        return Measurement(
            paperWidth: CGFloat(right - left + 1) / Self.scale,
            captionStartX: CGFloat(inkColumn - left) / Self.scale
        )
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
