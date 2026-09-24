@testable import LittleSprout
import SwiftUI
import XCTest

/// LS-366：時間軸互動列未按讚態字色（`InteractionRow.idleForeground`）在互動列**實際**
/// 底色上的 WCAG 對比。互動列落在 theme-aware 底色（`DiaryCardView` 的 `lsSurface`、
/// `PhotoCardView`／`AlbumCardView` 相紙外的 `lsBackground`，其 radial 漸層另一端
/// `lsBackgroundLit`），不是 `print-paper` 紙面——曾經誤用紙上專用的單值 token
/// `print-ink-secondary`，深色只剩 1.44–1.69:1，長輩幾乎看不見「留言 N」。
/// 4.5:1 是長輩硬約束（一般文字 AA）；淺色必須與舊值一致（票文範圍 3「淺色不變」）。
///
/// `@MainActor`（LS-371，池 `10c04878`）：`InteractionRow` 是 View、其 static 屬性跟著屬於
/// MainActor，非隔離 test method 讀取會出 main-actor isolation warning。
@MainActor
final class InteractionRowContrastTests: XCTestCase {
    private static let elderMinimumContrast = 4.5

    private func resolve(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    /// WCAG 2.1 相對亮度——`Color.Resolved.linearRed`／`linearGreen`／`linearBlue` 已是線性 sRGB，不必再做 gamma 展開。
    private func luminance(_ color: Color.Resolved) -> Double {
        0.2126 * Double(color.linearRed) + 0.7152 * Double(color.linearGreen) + 0.0722 * Double(color.linearBlue)
    }

    private func contrast(_ lhs: Color.Resolved, _ rhs: Color.Resolved) -> Double {
        let (lighter, darker) = (max(luminance(lhs), luminance(rhs)), min(luminance(lhs), luminance(rhs)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    func test_idleForeground_meetsElderContrastOnActualRowBackgrounds_inBothSchemes() {
        let backgrounds: [(String, Color)] = [
            ("surface", .lsSurface), ("bg", .lsBackground), ("bg-lit", .lsBackgroundLit)
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, background) in backgrounds {
                let ratio = contrast(resolve(InteractionRow.idleForeground, scheme), resolve(background, scheme))
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.elderMinimumContrast,
                    "互動列字色對 \(name)（\(scheme)）只有 \(String(format: "%.2f", ratio)):1，低於長輩硬約束 4.5:1"
                )
            }
        }
    }

    func test_idleForeground_lightScheme_unchangedFromPreviousPrintInkSecondary() {
        let now = resolve(InteractionRow.idleForeground, .light)
        let before = resolve(.lsPrintInkSecondary, .light)
        XCTAssertEqual(now.red, before.red, accuracy: 0.001, "淺色互動列字色不得改變（票文範圍 3）")
        XCTAssertEqual(now.green, before.green, accuracy: 0.001, "淺色互動列字色不得改變（票文範圍 3）")
        XCTAssertEqual(now.blue, before.blue, accuracy: 0.001, "淺色互動列字色不得改變（票文範圍 3）")
    }

    // MARK: - LS-371：Count Zone 實際渲染後的計數對比（三態）

    /// LS-371：讚數 N=0 時 `Count Zone` 曾掛 `.disabled(reaction.count == 0)`，SwiftUI 把
    /// `.plain` 按鈕整顆淡化約 50%，計數「0」深色 3.07:1、淺色 2.47–2.63:1（LS-366 QA
    /// `06a94284`）——字色 token 本身合格，淡化發生在渲染層，上面兩支色值測試量不到。
    /// 這支用 `ImageRenderer` 把整條 `InteractionRow` 畫在互動列實際底色上，只取 `Count Zone`
    /// 那一段像素，量「最深／最亮的字心像素」對底色像素的 WCAG 對比：淡化會把字心混向底色、
    /// 對比直接掉到 4.5 以下。三態＝0 讚／N>0 未按讚（`idleForeground`）／已按讚（`lsAccent`）。
    func test_countZone_renderedCountMeetsElderContrast_inAllReactionStates() throws {
        let states: [(String, ReactionState)] = [
            ("0 讚", ReactionState(count: 0, reactedByMe: false)),
            ("N>0 未按讚", ReactionState(count: 3, reactedByMe: false)),
            ("已按讚", ReactionState(count: 4, reactedByMe: true))
        ]
        let backgrounds: [(String, Color)] = [
            ("surface", .lsSurface), ("bg", .lsBackground), ("bg-lit", .lsBackgroundLit)
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (backgroundName, background) in backgrounds {
                for (stateName, state) in states {
                    let ratio = try renderedCountZoneContrast(state: state, background: background, scheme: scheme)
                    XCTAssertGreaterThanOrEqual(
                        ratio, Self.elderMinimumContrast,
                        "讚數（\(stateName)）渲染後對 \(backgroundName)（\(scheme)）只有 "
                            + "\(String(format: "%.2f", ratio)):1，低於長輩硬約束 4.5:1"
                    )
                }
            }
        }
    }

    private static let renderScale: CGFloat = 3
    private static let rowWidth: CGFloat = 390

    /// `Count Zone` 在標準字級下的水平範圍：`Like Toggle` 固定寬 118（`InteractionRow.likeToggleSize`）
    /// ＋`AppSpacing.tight`，熱區外框 48 寬（`minWidth: 48`）。左右各內縮 2pt，避開相鄰元件的反鋸齒邊。
    private static var countZoneXRange: ClosedRange<CGFloat> {
        let start = 118 + AppSpacing.tight
        return (start + 2)...(start + 46)
    }

    private func renderedCountZoneContrast(
        state: ReactionState, background: Color, scheme: ColorScheme
    ) throws -> Double {
        let store = TimelineStore.preview()
        let refId = UUID()
        store.seedReactionState(state, forKey: TimelineEntry.id(kind: .diary, refId: refId))
        let content = InteractionRow(kind: .diary, refId: refId, timelineStore: store, familyStore: .preview())
            .frame(width: Self.rowWidth, alignment: .leading)
            .background(background)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.renderScale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 沒有產出影像")
        let pixels = try SRGBPixels(image)

        // 背景取左上角（`Like Toggle` 有 padding 11，此處一定是底色）。
        let backgroundPixel = pixels.luminance(column: 1, row: 1)
        let xRange = Self.countZoneXRange
        let minX = Int(xRange.lowerBound * Self.renderScale)
        let maxX = Int(xRange.upperBound * Self.renderScale)
        var best = 1.0
        for row in 0..<pixels.height {
            for column in minX..<min(maxX, pixels.width) {
                let lum = pixels.luminance(column: column, row: row)
                let ratio = (max(lum, backgroundPixel) + 0.05) / (min(lum, backgroundPixel) + 0.05)
                best = max(best, ratio)
            }
        }
        return best
    }
}

/// 把任意 `CGImage` 重畫進 8-bit sRGB RGBA 點陣，統一色彩空間後才能用 WCAG sRGB 公式算亮度。
/// LS-373：改 internal，`Import05FillBabiesButtonContrastTests` 共用。
struct SRGBPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "無法建立 sRGB 點陣 context")
        bytes = buffer
    }

    /// LS-389：8-bit sRGB 三通道原值（`CardImprintInsetContrastTests` 判斷像素是否落在紙色→池色直線上）。
    func rgb(column: Int, row: Int) -> SIMD3<Double> {
        let offset = (row * width + column) * 4
        return SIMD3(Double(bytes[offset]), Double(bytes[offset + 1]), Double(bytes[offset + 2]))
    }

    /// WCAG 2.1 相對亮度（8-bit sRGB → 線性）。底色不透明，premultiplied 不影響結果。
    func luminance(column: Int, row: Int) -> Double {
        let offset = (row * width + column) * 4
        func linear(_ value: UInt8) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(bytes[offset]) + 0.7152 * linear(bytes[offset + 1]) + 0.0722 * linear(bytes[offset + 2])
    }
}
