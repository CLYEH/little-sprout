@testable import LittleSprout
import SwiftUI
import UIKit
import XCTest

/// LS-440：`ThumbnailCountLabel`（Notes `sErBN`＋LS-439 `F3GbnN`）。
///
/// 長短形是 `ViewThatFits` 依「可用寬度」決定的，所以門檻測試不複製一份判斷式，而是把真的標籤放進
/// 指定寬度的容器、用 `UIHostingController.sizeThatFits` 量它**實際選了哪一形**：`ViewThatFits`
/// 回報的是被選中那一形的尺寸，拿它去比同字級下純 `Text` 的長形／短形寬度即可分辨。稿面規格值
/// （F3GbnN 對照表二）：可用寬＝格寬 − 2×`$sp-tight`（96 格 84、64 格 52）；預設字級長形一位數 69／
/// 兩位數 79、三位數 89；AX3 長形一位數約 162、兩位數約 186。
@MainActor
final class ThumbnailCountLabelTests: XCTestCase {
    private let tight = AppSpacing.tight

    // MARK: - 字串與 codepoint

    func test_longText_hasNBSPOnBothSidesOfTheNumber_andNoPlainSpace() {
        let text = ThumbnailCountLabel.longText(21)
        XCTAssertEqual(
            Array(text.unicodeScalars.map(\.value)),
            [0x9084, 0x6709, 0x00A0, 0x32, 0x31, 0x00A0, 0x5F35],
            "長形應為「還有」U+00A0 數字 U+00A0「張」；實際 codepoint：\(text.unicodeScalars.map { String($0.value, radix: 16) })"
        )
        XCTAssertFalse(text.contains(" "), "長形不得含一般空白（U+0020）——會在數字旁斷行")
    }

    func test_shortText_isPlusNWithoutAnySpace() {
        XCTAssertEqual(ThumbnailCountLabel.shortText(128), "+128")
        XCTAssertEqual(ThumbnailCountLabel.shortText(3).unicodeScalars.map(\.value), [0x2B, 0x33])
    }

    func test_spokenText_isAlwaysLongForm_forSameN() {
        for count in [1, 3, 28, 128] {
            XCTAssertEqual(ThumbnailCountLabel.spokenText(count), ThumbnailCountLabel.longText(count), "N=\(count)")
        }
    }

    // MARK: - 校準：量測環境真的在跑稿面字級

    func test_calibration_defaultSize_longFormWidthsMatchNotes() {
        // 稿面實測 69／79／89（F3GbnN）；容許字型渲染差 ±6pt。
        assertWidth(Self.plainWidth(ThumbnailCountLabel.longText(3), .large), near: 69, tolerance: 6)
        assertWidth(Self.plainWidth(ThumbnailCountLabel.longText(21), .large), near: 79, tolerance: 6)
        assertWidth(Self.plainWidth(ThumbnailCountLabel.longText(128), .large), near: 89, tolerance: 6)
    }

    func test_calibration_ax3_longFormIsFarTooWideForAnyCell() {
        // 稿面 AX3（40pt）長形一位數約 162、兩位數約 186；app 的 `.note` 在 iOS 26.5 模擬器 AX3 實際約 37pt
        // （`@ScaledMetric(relativeTo: .body)` 曲線，Typography.swift 檔頭「不逐一寫死 AX3 值」），所以量到
        // 144／161——不拿稿面絕對值硬比，只要求「遠大於 96 格可用寬 84」且約為預設字級的 2 倍以上。
        for count in [3, 21] {
            let ax3 = Self.plainWidth(ThumbnailCountLabel.longText(count), .accessibility3)
            let large = Self.plainWidth(ThumbnailCountLabel.longText(count), .large)
            XCTAssertGreaterThan(ax3, 84 + 40, "AX3 長形 N=\(count) 量到 \(ax3)，96 格可用寬 84 一律放不下")
            XCTAssertGreaterThan(ax3 / large, 1.9, "AX3 應明顯放大（\(ax3) / \(large)）")
        }
    }

    // MARK: - 長短形切換門檻（預設字級）

    func test_default_96Cell_oneAndTwoDigits_showLongForm() {
        for count in [3, 21] {
            XCTAssertEqual(form(count: count, cell: 96, size: .large), .long, "96 格 N=\(count) 放得下長形")
        }
    }

    func test_default_96Cell_threeDigits_fallsBackToShortBecauseOfInset() {
        // F3GbnN：長形「還有 128 張」寬 89 > 84（96 − 2×6）→ 短形「+128」；沒有內距時 89 ≤ 96 會放得下——
        // 這條同時守住「內距在 ViewThatFits 外側」。
        XCTAssertEqual(form(count: 128, cell: 96, size: .large), .short)
        XCTAssertEqual(
            form(count: 128, cell: 96, size: .large, inset: 0), .long, "對照組：內距 0 時 89 ≤ 96，長形放得下（日記卡無內距）"
        )
    }

    func test_default_64Cell_longFormNeverFits_showsShort() {
        for count in [3, 28, 128] {
            XCTAssertEqual(form(count: count, cell: 64, size: .large), .short, "64 格可用寬 52，長形 ≥69 放不下，N=\(count)")
        }
    }

    // MARK: - AX3

    func test_ax3_96Cell_oneAndTwoDigits_showShortAtFullSize() {
        for count in [3, 21] {
            XCTAssertEqual(form(count: count, cell: 96, size: .accessibility3), .short, "AX3 長形 ≥162 一律放不下，N=\(count)")
            let shortIdeal = Self.plainWidth(ThumbnailCountLabel.shortText(count), .accessibility3)
            let measured = Self.hostedWidth(count: count, cell: 96, size: .accessibility3, inset: tight) - 2 * tight
            XCTAssertEqual(measured, shortIdeal, accuracy: 1, "AX3 96 格 N=\(count) 短形 ≤84 不需縮放")
        }
    }

    func test_ax3_64Cell_twoDigits_scalesShortFormIntoAvailableWidth() {
        // F3GbnN：「+28」AX3 短形寬 71 > 52 → minimumScaleFactor 縮放，稿面比例 52/71＝0.73（畫 29pt）。
        let ideal = Self.plainWidth(ThumbnailCountLabel.shortText(28), .accessibility3)
        let available: CGFloat = 52
        XCTAssertGreaterThan(ideal, available, "前提：AX3 短形在 64 格放不下")
        let ratio = available / ideal
        XCTAssertEqual(ratio, 0.73, accuracy: 0.06, "縮放比例應貼稿面 0.73（29/40）；實測 \(ratio)")
        let measured = Self.hostedWidth(count: 28, cell: 64, size: .accessibility3, inset: tight) - 2 * tight
        XCTAssertLessThanOrEqual(measured, available + 0.5, "縮放後必須收進內距內，不溢出")
        XCTAssertGreaterThanOrEqual(measured, ideal * ThumbnailCountLabel.minimumScaleFactor, "不得縮過 0.5")
    }

    func test_ax3_threeDigits_scalesInBothCells_andStaysAboveHalfScale() {
        // F3GbnN 壓測：96 格 +128 縮到 35pt（84/95＝0.88）、64 格縮到 21pt（52/95＝0.547，仍高於 0.5 下限）。
        let ideal = Self.plainWidth(ThumbnailCountLabel.shortText(128), .accessibility3)
        for (cell, available, specRatio) in [(96.0, 84.0, 0.88), (64.0, 52.0, 0.547)] {
            let measured = Self.hostedWidth(count: 128, cell: cell, size: .accessibility3, inset: tight) - 2 * tight
            XCTAssertLessThanOrEqual(measured, available + 0.5, "\(Int(cell)) 格 +128 必須收進可用寬 \(available)")
            let ratio = available / ideal
            XCTAssertGreaterThanOrEqual(ratio, ThumbnailCountLabel.minimumScaleFactor, "\(Int(cell)) 格縮放比例低於 0.5")
            XCTAssertEqual(ratio, specRatio, accuracy: 0.1, "\(Int(cell)) 格縮放比例貼稿面 \(specRatio)；實測 \(ratio)")
        }
    }

    func test_nowhereOverflows_acrossCellsCountsAndSizes() {
        let sizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
        for size in sizes {
            for cell in [64.0, 96.0] {
                for count in [1, 9, 28, 99, 128, 200] {
                    let width = Self.hostedWidth(count: count, cell: cell, size: size, inset: tight)
                    XCTAssertLessThanOrEqual(width, cell + 0.5, "\(size) \(Int(cell)) 格 N=\(count) 標籤寬 \(width) 溢出格寬")
                }
            }
        }
    }

    // MARK: - 兩處共用同一元件（驗收 1）

    func test_importMoreCell_and_diaryCard_bothUseThumbnailCountLabel() throws {
        let importSource = try Self.sourceText("LittleSprout/Features/Import/ImportThumbnailLayout.swift")
        let diarySource = try Self.sourceText("LittleSprout/Features/Timeline/DiaryCardView.swift")
        XCTAssertTrue(
            importSource.contains("ThumbnailCountLabel(count: count"), "ImportMoreCell 應該用 ThumbnailCountLabel"
        )
        XCTAssertTrue(
            importSource.contains("horizontalInset: AppSpacing.tight"), "Import More Cell 內距 $sp-tight（F3GbnN bPD0S）"
        )
        XCTAssertTrue(
            diarySource.contains("ThumbnailCountLabel(count: remainingPhotoCount"), "日記卡暗蓋應該用 ThumbnailCountLabel"
        )
        XCTAssertFalse(diarySource.contains("Text(\"還有"), "日記卡不得再自己拼「還有 N 張」")
        XCTAssertFalse(importSource.contains("Text(\"+"), "Import 不得再自己拼「+N」")
    }

    // MARK: - 量測工具

    private enum Form { case long, short }

    /// 把真的標籤放進 `cell` 寬容器，量它的實際寬度，與同字級純 Text 長／短形寬度（＋內距）比，判斷它選了哪一形。
    private func form(count: Int, cell: CGFloat, size: DynamicTypeSize, inset: CGFloat? = nil) -> Form {
        let inset = inset ?? tight
        let width = Self.hostedWidth(count: count, cell: cell, size: size, inset: inset)
        let long = Self.plainWidth(ThumbnailCountLabel.longText(count), size) + 2 * inset
        let short = Self.plainWidth(ThumbnailCountLabel.shortText(count), size) + 2 * inset
        if abs(width - long) <= 1 { return .long }
        if abs(width - short) <= 1 || width < long { return .short }
        XCTFail("量到的寬 \(width) 既不是長形 \(long) 也不是短形 \(short)")
        return .short
    }

    private static func hostedWidth(count: Int, cell: CGFloat, size: DynamicTypeSize, inset: CGFloat) -> CGFloat {
        let view = ThumbnailCountLabel(count: count, foreground: .primary, horizontalInset: inset)
            .environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: cell, height: 400)).width
    }

    private static func plainWidth(_ string: String, _ size: DynamicTypeSize) -> CGFloat {
        let view = Text(string).appFont(.note, weight: .bold).lineLimit(1).fixedSize()
            .environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 1000, height: 400)).width
    }

    private func assertWidth(
        _ width: CGFloat, near expected: CGFloat, tolerance: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(width, expected, accuracy: tolerance, "量測環境與稿面字級不符", file: file, line: line)
    }

    private static func sourceText(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
