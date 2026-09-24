@testable import LittleSprout
import SwiftUI
import XCTest

/// LS-373 D5：「補上寶貝」進行中（停用）態實際渲染後的字色對比。稿面（Notes `XG9yu`）要求停用態
/// label 用 $text-secondary 原色（淺 7.91:1／深 8.78:1），不再疊系統的 disabled 淡化——`.plain`
/// 會把整顆調淡約 50%，字色 token 合格但渲染後掉到 4.5 以下（同 LS-371 Count Zone 的教訓），
/// 色值測試量不到，這裡用 `ImageRenderer` 量像素。
@MainActor
final class Import05FillBabiesButtonContrastTests: XCTestCase {
    private static let elderMinimumContrast = 4.5
    private static let renderScale: CGFloat = 3

    func test_inFlightLabel_renderedContrastMeetsElderMinimum_onBothBackgroundEnds_inBothSchemes() throws {
        let backgrounds: [(String, Color)] = [("bg", .lsBackground), ("bg-lit", .lsBackgroundLit)]
        for scheme in [ColorScheme.light, .dark] {
            for (name, background) in backgrounds {
                let ratio = try renderedContrast(isInFlight: true, background: background, scheme: scheme)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.elderMinimumContrast,
                    "「正在補上寶貝…」渲染後對 \(name)（\(scheme)）只有 \(String(format: "%.2f", ratio)):1，"
                        + "低於長輩硬約束 4.5:1——停用態被系統淡化了（LS-373 D5）"
                )
            }
        }
    }

    /// 最深／最亮的字心像素對底色像素的 WCAG 對比（左上角有 padding，一定是底色）。
    private func renderedContrast(isInFlight: Bool, background: Color, scheme: ColorScheme) throws -> Double {
        let content = Import05FillBabiesButton(count: 3, isInFlight: isInFlight, action: {})
            .frame(width: 390, alignment: .leading)
            .background(background)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.renderScale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 沒有產出影像")
        let pixels = try SRGBPixels(image)
        let backgroundLuminance = pixels.luminance(column: 1, row: 1)
        var best = 1.0
        for row in 0..<pixels.height {
            for column in 0..<pixels.width {
                let lum = pixels.luminance(column: column, row: row)
                best = max(best, (max(lum, backgroundLuminance) + 0.05) / (min(lum, backgroundLuminance) + 0.05))
            }
        }
        return best
    }
}
