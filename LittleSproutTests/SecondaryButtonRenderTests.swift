@testable import LittleSprout
import SwiftUI
import XCTest

/// LS-450（LS-449 C1a／C3b）：`SecondaryButton` 對稿——預設照稿 `XggYA`（body 半粗 600），歡迎頁登入三鈕
/// 具名豁免（lead medium，主人：官方 Apple 鈕）；Google／Email 標題「登」「入」之間 U+2060，AX3 換行不拆
/// 「登入」並置中（稿 `e7G3Lk`／`aEb17`）。
///
/// 沿用 `PrimaryButtonRenderTests` 的做法：`ImageRenderer` 量**畫出來**的墨量與換行，而不是只斷言常數。
/// 文字墨量＝（有標題的鈕）減（同鈕空標題）的亮度差總和，扣掉外框與圖示。
@MainActor
final class SecondaryButtonRenderTests: XCTestCase {
    private static let renderScale: CGFloat = 3
    private static let width: CGFloat = 390
    private static let title = "加入照片"

    // MARK: - 字重（C1a）

    /// 預設（所有非歡迎頁呼叫端）：墨量等同 `.body` semibold 參考文字，且明顯多於 medium。
    func test_default_labelRendersBodySemibold() throws {
        let button = try textInk(of: SecondaryButton(icon: "xmark", title: Self.title, action: {}))
        let semibold = try textInk(of: referenceLabel(.body, .semibold))
        let medium = try textInk(of: referenceLabel(.body, .medium))
        let bold = try textInk(of: referenceLabel(.body, .bold))

        XCTAssertEqual(
            button / semibold, 1, accuracy: 0.03,
            "次要鈕預設文字墨量應等同 body semibold 參考（比值 \(button / semibold)；"
                + "medium／semibold＝\(medium / semibold)，bold／semibold＝\(bold / semibold)）——"
                + "字重沒套上 semibold（稿 XggYA 600，LS-449 C1a）"
        )
        XCTAssertGreaterThan(
            button / medium, 1.03,
            "次要鈕預設文字應比 medium 重（比值 \(button / medium)）：稿 600，不是舊的 lead medium"
        )
    }

    /// 歡迎頁 Email 鈕傳 lead medium（C3 具名豁免）：字級與字重都跟著參數，不被預設吃掉。
    func test_welcomeEmail_labelRendersLeadMedium() throws {
        let button = try textInk(of: SecondaryButton(
            icon: "envelope", title: Self.title, labelToken: .lead, labelWeight: .medium, action: {}
        ))
        let leadMedium = try textInk(of: referenceLabel(.lead, .medium))
        let bodySemibold = try textInk(of: referenceLabel(.body, .semibold))

        XCTAssertEqual(
            button / leadMedium, 1, accuracy: 0.03,
            "傳 lead medium 的次要鈕文字墨量應等同 lead medium 參考（比值 \(button / leadMedium)）"
        )
        XCTAssertGreaterThan(
            button / bodySemibold, 1.2,
            "lead 22pt 文字墨量應明顯多於 body 17pt（比值 \(button / bodySemibold)）——字級參數沒傳進去"
        )
    }

    // MARK: - U+2060 與置中（C3b）

    /// AX3：Google 鈕標題換行時，「登入」不被拆開（沒有單字「入」孤行）。孤字行寬約一個字（< 行高 1.5 倍）。
    /// 單一寬度可能剛好「登」放得下、「入」放不下才拆，所以掃一段寬度（窄機型到 iPhone 17 Pro 之外）：
    /// 任何寬度出現孤字行就紅。
    func test_googleTitle_accessibility3_neverSplitsDengRu() throws {
        try assertNoOrphanLine(in: "Google", widths: Self.sweepWidths) { GoogleSignInButton(action: {}) }
    }

    /// 歡迎頁 Email 鈕（SecondaryButton＋Email 標題）同理；390pt 寬 AX3 時 Email 標題剛好一行，所以掃的寬度
    /// 涵蓋更窄的範圍，U+2060 才有東西可守。
    func test_emailTitle_accessibility3_neverSplitsDengRu() throws {
        try assertNoOrphanLine(in: "Email", widths: Self.sweepWidths) {
            SecondaryButton(
                icon: "envelope", title: WelcomeButtonTitle.email, labelToken: .lead, labelWeight: .medium, action: {}
            )
        }
    }

    private static let sweepWidths = Array(stride(from: 240 as CGFloat, through: 390, by: 2))

    private func assertNoOrphanLine(
        in name: String, widths: [CGFloat], file: StaticString = #filePath, line: UInt = #line,
        button: () -> some View
    ) throws {
        var wrapped = 0
        var orphans: [String] = []
        for width in widths {
            let lines = try textLines(of: button(), size: .accessibility3, width: width)
            if lines.count >= 2 { wrapped += 1 }
            guard let shortest = lines.map(\.width).min(), let tallest = lines.map(\.height).max() else { continue }
            if shortest <= tallest * 1.5 { orphans.append("寬 \(width)pt → \(lines)") }
        }
        XCTAssertGreaterThan(wrapped, 0, "\(name) 鈕掃過的寬度都沒換行（前提不成立）", file: file, line: line)
        XCTAssertTrue(
            orphans.isEmpty,
            "AX3 \(name) 鈕出現孤字行——「登」「入」之間少了 U+2060，換行把「登入」拆開（LS-449 C3b）：\n"
                + orphans.joined(separator: "\n"),
            file: file, line: line
        )
    }

    /// AX3 兩行置中（稿為置中；SwiftUI 多行預設靠左）：兩行的水平中心差 ≤ 2pt。
    func test_googleTitle_accessibility3_linesAreCentered() throws {
        let lines = try textLines(of: GoogleSignInButton(action: {}), size: .accessibility3)
        XCTAssertGreaterThanOrEqual(lines.count, 2, "AX3 下 Google 鈕標題應換行（前提不成立）：\(lines)")
        let centers = lines.map(\.centerX)
        let spread = (centers.max() ?? 0) - (centers.min() ?? 0)
        XCTAssertLessThanOrEqual(
            spread, 2,
            "AX3 多行標題應置中（各行中心差 \(spread)pt）——缺 .multilineTextAlignment(.center)；各行：\(lines)"
        )
    }

    /// VoiceOver／UITest 看到的標籤不含 U+2060。
    func test_welcomeTitles_cleanedLabelHasNoJoiner() {
        XCTAssertEqual(WelcomeButtonTitle.cleaned(WelcomeButtonTitle.google), "使用 Google 登入")
        XCTAssertEqual(WelcomeButtonTitle.cleaned(WelcomeButtonTitle.email), "使用 Email 登入")
        XCTAssertTrue(WelcomeButtonTitle.google.contains("登\u{2060}入"))
        XCTAssertTrue(WelcomeButtonTitle.email.contains("登\u{2060}入"))
    }

    // MARK: - 渲染

    private struct TextLine: CustomStringConvertible {
        let width: CGFloat
        let height: CGFloat
        let centerX: CGFloat
        var description: String { "[x中心 \(centerX)pt 寬 \(width)pt 高 \(height)pt]" }
    }

    /// 明確指定字級／字重的次要鈕，當墨量參考（其餘與預設鈕相同）。
    private func referenceLabel(_ token: AppFontToken, _ weight: Font.Weight) -> SecondaryButton {
        SecondaryButton(icon: "xmark", title: Self.title, labelToken: token, labelWeight: weight, action: {})
    }

    private func render(_ view: some View, size: DynamicTypeSize, width: CGFloat = SecondaryButtonRenderTests.width)
        throws -> SRGBPixels {
        let content = view
            .frame(width: width)
            .padding(.vertical, 4)
            .background(Color.white)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.renderScale
        return try SRGBPixels(XCTUnwrap(renderer.cgImage, "ImageRenderer 沒有產出影像"))
    }

    private func inkSum(_ pixels: SRGBPixels) -> Double {
        let background = pixels.luminance(column: 1, row: 1)
        var total = 0.0
        for row in 0..<pixels.height {
            for column in 0..<pixels.width {
                total += abs(pixels.luminance(column: column, row: row) - background)
            }
        }
        return total
    }

    /// 文字墨量：有標題的鈕減同鈕空標題（外框、圖示、底色相同），只剩文字。
    private func textInk(of button: SecondaryButton) throws -> Double {
        let withTitle = try inkSum(render(button, size: .large))
        let blank = SecondaryButton(
            icon: button.icon, title: "", labelToken: button.labelToken, labelWeight: button.labelWeight, action: {}
        )
        return try withTitle - inkSum(render(blank, size: .large))
    }

    /// 切出按鈕內每一行文字的水平延伸：先量空標題鈕的圖示右緣，只看其右側（扣掉外框與圖示）。
    private func textLines(
        of button: some View, size: DynamicTypeSize, width: CGFloat = SecondaryButtonRenderTests.width
    ) throws -> [TextLine] {
        let scale = Self.renderScale
        let pixels = try render(button, size: size, width: width)
        // 右緣留 20pt（按鈕水平 padding）：外框圓角弧線不算文字。
        let rightLimit = pixels.width - Int(20 * scale)
        let background = pixels.luminance(column: Int(6 * scale), row: pixels.height / 2)
        let leftEdge = Int(24 * scale)
        // 圖示右緣：圖示與文字之間的 label spacing 之後才是文字；以「第一個連續 ≥ 6pt 的空白欄」為界。
        var textStart = leftEdge
        var seenInk = false
        var gap = 0
        for column in leftEdge..<rightLimit {
            let hasInk = columnHasInk(pixels, column: column, background: background)
            if hasInk { seenInk = true; gap = 0 } else if seenInk {
                gap += 1
                if CGFloat(gap) >= 6 * scale { textStart = column; break }
            }
        }
        var lines: [TextLine] = []
        var currentTop: Int?
        var minColumn = Int.max
        var maxColumn = 0
        let top = Int(8 * scale)
        let bottom = pixels.height - Int(8 * scale)
        func close(at row: Int) {
            guard let start = currentTop else { return }
            lines.append(TextLine(
                width: CGFloat(maxColumn - minColumn + 1) / scale,
                height: CGFloat(row - start) / scale,
                centerX: CGFloat(minColumn + maxColumn) / 2 / scale
            ))
            currentTop = nil
            minColumn = Int.max
            maxColumn = 0
        }
        for row in top..<bottom {
            var rowMin = Int.max
            var rowMax = 0
            for column in textStart..<rightLimit
            where abs(pixels.luminance(column: column, row: row) - background) > 0.25 {
                rowMin = min(rowMin, column)
                rowMax = max(rowMax, column)
            }
            if rowMax > 0 {
                if currentTop == nil { currentTop = row }
                minColumn = min(minColumn, rowMin)
                maxColumn = max(maxColumn, rowMax)
            } else {
                close(at: row)
            }
        }
        close(at: bottom)
        return lines
    }

    private func columnHasInk(_ pixels: SRGBPixels, column: Int, background: Double) -> Bool {
        let top = Int(8 * Self.renderScale)
        for row in top..<pixels.height - top
        where abs(pixels.luminance(column: column, row: row) - background) > 0.25 {
            return true
        }
        return false
    }
}
