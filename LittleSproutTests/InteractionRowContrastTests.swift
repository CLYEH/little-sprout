@testable import LittleSprout
import SwiftUI
import XCTest

/// LS-366：時間軸互動列未按讚態字色（`InteractionRow.idleForeground`）在互動列**實際**
/// 底色上的 WCAG 對比。互動列落在 theme-aware 底色（`DiaryCardView` 的 `lsSurface`、
/// `PhotoCardView`／`AlbumCardView` 相紙外的 `lsBackground`，其 radial 漸層另一端
/// `lsBackgroundLit`），不是 `print-paper` 紙面——曾經誤用紙上專用的單值 token
/// `print-ink-secondary`，深色只剩 1.44–1.69:1，長輩幾乎看不見「留言 N」。
/// 4.5:1 是長輩硬約束（一般文字 AA）；淺色必須與舊值一致（票文範圍 3「淺色不變」）。
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
}
