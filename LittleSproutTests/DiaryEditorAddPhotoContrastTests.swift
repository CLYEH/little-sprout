@testable import LittleSprout
import SwiftUI
import XCTest

/// LS-368：日記編輯器「新增照片」格 icon／字色（`DiaryEditorView.addPhotoForeground`）在格子
/// **實際**底色（`DiaryEditorView.addPhotoBackground`＝`lsSurface2`，隨 theme 變）上的 WCAG
/// 對比。曾經誤用紙上專用的單值 token `print-ink-secondary`（不掛 theme，只在 `$print-paper`
/// 上合法），深色對 surface-2 只剩 1.27:1，長輩看不見「新增照片」。
/// 4.5:1 是長輩硬約束（一般文字 AA）；淺色必須與舊值一致（票文範圍 2「淺色值不變」）。
/// 寫法沿 `InteractionRowContrastTests`（LS-366）。
final class DiaryEditorAddPhotoContrastTests: XCTestCase {
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

    func test_addPhotoForeground_meetsElderContrastOnCellBackground_inBothSchemes() {
        for scheme in [ColorScheme.light, .dark] {
            let ratio = contrast(
                resolve(DiaryEditorView.addPhotoForeground, scheme),
                resolve(DiaryEditorView.addPhotoBackground, scheme)
            )
            XCTAssertGreaterThanOrEqual(
                ratio, Self.elderMinimumContrast,
                "「新增照片」格字色對格底（\(scheme)）只有 \(String(format: "%.2f", ratio)):1，低於長輩硬約束 4.5:1"
            )
        }
    }

    func test_addPhotoForeground_lightScheme_unchangedFromPreviousPrintInkSecondary() {
        let now = resolve(DiaryEditorView.addPhotoForeground, .light)
        let before = resolve(.lsPrintInkSecondary, .light)
        XCTAssertEqual(now.red, before.red, accuracy: 0.001, "淺色「新增照片」字色不得改變（票文範圍 2）")
        XCTAssertEqual(now.green, before.green, accuracy: 0.001, "淺色「新增照片」字色不得改變（票文範圍 2）")
        XCTAssertEqual(now.blue, before.blue, accuracy: 0.001, "淺色「新增照片」字色不得改變（票文範圍 2）")
    }
}
