@testable import LittleSprout
import CoreText
import UIKit
import XCTest

/// LS-406（LS-388 範圍 1／驗收 1）：相簿卡 Caption 一般字級單串「標題 ·<NBSP>N<NBSP>張⁠相⁠片」的實際折行位置——
/// 折行只能落在標題內或「·」前，「· N 張相片」整段不拆行（不留「·」孤在行尾、不留「N」「張」「相」「片」孤字）。
///
/// 量法：CoreText `CTTypesetter` 以真實 Caption 字串與 semibold system font 逐寬度斷行（SwiftUI `Text` 走同一套
/// Unicode 斷行規則；NBSP／WORD JOINER 的禁斷語意在此可直接驗），掃「剛好放得下 `· N 張相片` 整段」到卡內欄寬的
/// 全部寬度，檢查每個斷點都不落在「·」之後。AX3 的兩行態（`isMultiline`）由 `\n` 顯式分行、不在此列。
final class AlbumCaptionLineBreakTests: XCTestCase {
    private static let longTitle = "阿公阿嬤全家福二〇二六跨年夜溫馨團聚倒數紀念相片珍藏加長版本紀念冊"

    func test_regularCaption_neverBreaksAfterMiddleDot_acrossWidthsAndFontSizes() throws {
        for title in [Self.longTitle, "弟弟出生的第一週", "2026 夏天的海邊"] {
            let text = AlbumSignatureFormatter.captionText(title: title, photoCount: 8, isMultiline: false)
            let nsText = text as NSString
            let dot = nsText.range(of: "·").location
            XCTAssertNotEqual(dot, NSNotFound)
            let unit = nsText.substring(from: dot) as NSString
            // 17＝Large；23／28／33＝AX 以下各檔；40／47／53＝AX3／AX4／AX5 body（時間軸相簿卡 AX3 起也走這條單串，LS-406 R2）。
            for fontSize in [17.0, 23.0, 28.0, 33.0, 40.0, 47.0, 53.0] {
                let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let unitWidth = ceil(unit.size(withAttributes: attributes).width)
                let attributed = NSAttributedString(string: text, attributes: attributes)
                let typesetter = CTTypesetterCreateWithAttributedString(attributed)
                // 卡內欄寬上限：iPhone 17 Pro 402－2×screenPad 24－2×printEdge 8－2×group 12＝314。
                for width in stride(from: unitWidth + 1, through: max(unitWidth + 1, 314), by: 1) {
                    var start = 0
                    while start < nsText.length {
                        let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                        let end = start + count
                        let firstLine = nsText.substring(with: NSRange(location: start, length: count))
                        if end < nsText.length {
                            XCTAssertFalse(
                                end > dot,
                                "[\(title.prefix(6))…/\(fontSize)pt/寬\(width)] 斷點 \(end) 落在「·」（\(dot)）之後，"
                                    + "「· N 張相片」被拆行：第一段「\(firstLine)」"
                            )
                        }
                        start = end
                    }
                }
            }
        }
    }

    /// 對照組：確認量法真的量得到斷點——超長標題在窄寬度下確實會在標題內折行（斷點都 ≤「·」位置）。
    func test_regularCaption_longTitleDoesWrapInsideTitle() {
        let text = AlbumSignatureFormatter.captionText(title: Self.longTitle, photoCount: 8, isMultiline: false)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: UIFont.systemFont(ofSize: 33, weight: .semibold)]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        XCTAssertLessThan(
            CTTypesetterSuggestLineBreak(typesetter, 0, 314), (text as NSString).length,
            "AX 字級超長標題在 314pt 應折行（量法要量得到斷點才有意義）"
        )
    }
}
