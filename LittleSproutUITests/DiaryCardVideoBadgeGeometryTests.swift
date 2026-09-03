import Vision
import XCTest

/// merge-review `443ec21a`：a11y tree 讀得出徽章的文字內容，但天生看不到「這段文字有沒有
/// 換行」「有沒有畫出格子邊界」——`443ec21a` 用 PR 附的截圖做像素量測才抓到日記卡預覽格的
/// 徽章換行成兩行（51.7pt）、右緣畫出卡片外（386.7pt，402pt 螢幕上卡片本該止於 378pt）。
/// 這裡直接量 `XCUIElement.frame`（螢幕座標，pt）把這兩類缺陷變成機械斷言。
///
/// **二輪自測踩到的第三個坑，記錄給後面改這支測試的人**：`XCUIElement.frame` 量到的是
/// `Text` 被分配到的排版框，不是實際畫出來的字元範圍——`Text` 用 `.lineLimit(1)` 把
/// 「影片 12:34」截斷成「影片 12:…」時，SwiftUI 不會把 frame 縮小去貼合省略號，
/// `accessibility label` 也照樣回報完整原字串（VoiceOver 本來就該唸完整內容，不該因為
/// 視覺截斷而唸半句）——frame 寬度、a11y label 兩條路都量不出「有沒有被截斷成省略號」。
/// 唯一能真的看到這件事的只有**畫面實際渲染出的像素**：對徽章元件單獨截圖後跑
/// `Vision` OCR，比對辨識出來的文字有沒有省略號、有沒有掉字——這才是名副其實的「像素量測」。
///
/// 用 `TapTargetGateHarness`（`LS_TAP_TARGET_GATE_SCREEN=DiaryCardVideoBadges`）餵一則
/// 帶 3 張附照的日記卡：1 張照片（無徽章）、1 支縮圖影片（恆「影片」，不觸發時長查詢）、
/// 1 支無縮圖舊影片（`durationLoader` 立即回傳 12:34——兩位數分鐘是最壞情況，同
/// reviewer 原文「分鐘數兩位會再寬 ~10pt，更糟」）。
@MainActor
final class DiaryCardVideoBadgeGeometryTests: XCTestCase {
    /// 稿面規格量到的單行徽章高度是 21pt（`design/littlesprout.pen` frame `xrCoj/sIJPp`，
    /// 見 `VideoDurationBadge` 文件註解）；換行成兩行時 R2 的截圖量到 51.7pt。閾值抓在中間
    /// （30pt）：留單行的合理容差（不同模擬器/字重渲染的 1-2pt 差異），但遠低於兩行門檻，
    /// 換行必定被抓到。
    private let maxSingleLineBadgeHeight: CGFloat = 30
    /// 時間軸版心（`AppSpacing.screenPad`）——`TapTargetGateHarness.diaryCardVideoBadgesHost`
    /// 用同一個值當卡片的水平 padding（`443ec21a` 量到的「卡片右緣本該止於 378pt」＝
    /// 402pt 螢幕寬 − 24pt screenPad，同一條算式）。UI test 跟 app target 是分離行程，
    /// 不能 `import LittleSprout` 引用 `AppSpacing.screenPad`（見
    /// `TapTargetGateScreenName.swift` 文件註解），字面值同步寫在這裡。
    private let screenPad: CGFloat = 24

    func testThumbnailVideoBadge_singleLine_withinCardBounds_ocrMatchesPlainLabel() throws {
        let app = launch()
        let badge = app.staticTexts["影片"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "縮圖影片格找不到「影片」徽章——恆顯示、不查時長")
        assertSingleLineAndWithinCardBounds(badge, app: app, label: "縮圖影片徽章")
        let recognized = try ocrText(of: badge)
        XCTAssertTrue(
            recognized.contains("影片") && !recognized.contains("…") && !recognized.contains("..."),
            "OCR 辨識縮圖影片徽章畫面內容為「\(recognized)」，預期是完整「影片」、不含省略號"
        )
    }

    func testLegacyVideoBadge_singleLine_withinCardBounds_ocrShowsFullDuration() throws {
        let app = launch()
        let badge = app.staticTexts["影片 12:34"]
        XCTAssertTrue(
            badge.waitForExistence(timeout: 10),
            "無縮圖舊影片格找不到「影片 12:34」——時長讀取或徽章接線可能沒生效"
        )
        assertSingleLineAndWithinCardBounds(badge, app: app, label: "無縮圖舊影片徽章")

        // M1 核心：`.frame`／a11y label 都量不出「畫面上是不是被截斷成省略號」（見檔頭
        // 註解），這裡對徽章單獨截圖跑 OCR，直接檢查渲染出來的像素有沒有完整的
        // 「12:34」與沒有省略號——這正是二輪自測實際踩到的迴歸（`.lineLimit(1)` 的預設
        // 收縮行為把「影片 12:34」悄悄截斷成「影片 12:…」，frame 高度／右緣兩條既有斷言
        // 完全抓不到，OCR 一次就抓到）。
        let recognized = try ocrText(of: badge)
        XCTAssertTrue(
            recognized.contains("12:34") || recognized.contains("12：34"),
            "OCR 辨識無縮圖舊影片徽章畫面內容為「\(recognized)」，看不到完整的「12:34」——"
                + "很可能被 `.lineLimit(1)` 悄悄截斷成「12:…」（frame 寬高本身量不出來這件事）"
        )
        XCTAssertFalse(
            recognized.contains("…") || recognized.contains("..."),
            "OCR 辨識無縮圖舊影片徽章畫面內容為「\(recognized)」，含有省略號——文字被截斷了"
        )
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = "DiaryCardVideoBadges"
        app.launch()
        return app
    }

    /// M1 幾何斷言：① 高度 ≤ `maxSingleLineBadgeHeight`（沒有換行成兩行）；② 右緣沒有超出
    /// 卡片右邊界（螢幕寬 − `screenPad`）——`443ec21a` 量到的兩個像素層級缺陷各自對應一條。
    /// 這兩條測得出「換行」「溢出卡片」，但測不出「原地截斷成省略號」（見檔頭註解），後者
    /// 靠呼叫端另外跑的 OCR 檢查。
    private func assertSingleLineAndWithinCardBounds(
        _ element: XCUIElement, app: XCUIApplication, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = element.frame
        XCTAssertGreaterThan(frame.width, 0, "\(label) frame 寬度是 0——元件可能沒有真的渲染", file: file, line: line)
        XCTAssertLessThanOrEqual(
            frame.height, maxSingleLineBadgeHeight,
            "\(label) 高度 \(fmt(frame.height))pt 超過單行門檻 \(Int(maxSingleLineBadgeHeight))pt"
                + "——很可能換行成兩行了（443ec21a 量到的日記卡缺陷：51.7pt）",
            file: file, line: line
        )
        let screenWidth = app.windows.firstMatch.frame.width
        let cardRightEdge = screenWidth - screenPad
        XCTAssertLessThanOrEqual(
            frame.maxX, cardRightEdge,
            "\(label) 右緣 \(fmt(frame.maxX))pt 超出卡片右邊界 \(fmt(cardRightEdge))pt"
                + "（螢幕寬 \(fmt(screenWidth))pt − screenPad \(Int(screenPad))pt）"
                + "——443ec21a 量到的日記卡缺陷：386.7pt 超出 378pt",
            file: file, line: line
        )
    }

    /// 對單一元件截圖後跑 `Vision` 文字辨識，回傳辨識到的所有文字（依信心分數取每段最佳
    /// 候選，用空白接起來）——這是本檔唯一真正檢查「畫面上實際畫出了什麼字元」的地方，
    /// 不透過 accessibility label／frame 這些「呼叫端宣稱的值」。
    private func ocrText(of element: XCUIElement) throws -> String {
        let screenshot = element.screenshot().image
        guard let cgImage = screenshot.cgImage else {
            XCTFail("截圖沒有 cgImage，OCR 無法進行")
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}
