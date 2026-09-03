import UIKit
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

    /// QA R4（`a356f033` FAIL）：`previewPhotosRow` 同列 tile 寬度不等、零間距、直式 tile
    /// 整個溢出卡片外。**實測發現：`XCUIElement.frame` 量不到這個缺陷類別，改用像素掃描。**
    /// 第一版寫法直接量 `previewTile<index>` 這個測試掛勾（`.overlay(Color.clear.
    /// accessibilityElement()...)`，見 `DiaryCardView.previewPhotosRow` 文件註解）的
    /// `.frame`——mutation 測試（拿掉 `.clipped()` 修復、重現 a356f033 的視覺缺陷）證實
    /// 這條會**漏掉真正的缺陷**：掛勾疊在外層 `previewPhotosRow` 呼叫端那個固定
    /// `.frame(width: previewTileSize, height: previewTileSize)` 上，那個外層 frame 本身
    /// 沒被這輪的迴歸動到，掛勾回報的永遠是「應該的」正方形 layout box，量不到「圖片內容
    /// 有沒有真的畫出界」——跟 R2 OCR 那次 `.frame` 量不到「原地截斷」是同一個模式：
    /// **layout box 回報值 ≠ 實際畫出來的像素**。
    ///
    /// 唯一可靠的辦法是直接讀螢幕截圖的像素顏色：harness（`TapTargetGateHarness.
    /// diaryCardVideoBadgesHost`）三張測試圖各用一個不會跟卡片背景混淆的純色字面值（橙／
    /// 藍／綠，`makeTestImageURL` 呼叫處），`measureTileExtent` 逐點掃描找出每個顏色實際
    /// 畫在螢幕上的範圍，直接量「畫出來的像素」多寬多高、彼此間有沒有間距、有沒有超出卡片
    /// 邊界——不透過任何呼叫端宣稱的 frame。
    func testPreviewTiles_sameRowUniformSquares_withinCardBounds() throws {
        let app = launch()
        // 用既有的 `previewTile<index>` 掛勾等到畫面穩定渲染（存在即可，這裡不用它的
        // `.frame` 做斷言依據，只當「畫面已經出現」的訊號）。
        XCTAssertTrue(app.otherElements["previewTile0"].waitForExistence(timeout: 10), "畫面沒有渲染出來")
        XCTAssertTrue(app.otherElements["previewTile1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["previewTile2"].waitForExistence(timeout: 5))

        let screenshot = app.screenshot().image
        guard let cgImage = screenshot.cgImage, let reader = PixelReader(cgImage: cgImage) else {
            XCTFail("截圖沒有 cgImage，無法做像素量測")
            return
        }
        let context = ScanContext(
            reader: reader, scale: screenshot.scale,
            screenWidth: app.windows.firstMatch.frame.width, screenHeight: app.windows.firstMatch.frame.height
        )
        // previewTile1（縮圖影片，第二格）的 accessibility 掛勾只用來選一條大概落在同列的
        // 掃描橫線——真正的判定完全靠掃到的像素顏色，不靠這個座標本身的寬高。
        let approxRowY = app.otherElements["previewTile1"].frame.midY

        guard let orange = measureTileExtent(matching: isOrangeTestColor, approxRowY: approxRowY, in: context) else {
            XCTFail("水平／垂直掃描找不到橙色格（previewTile0）——tile 可能沒有渲染或位置跟預期差太多")
            return
        }
        guard let blue = measureTileExtent(matching: isBlueTestColor, approxRowY: approxRowY, in: context) else {
            XCTFail("水平／垂直掃描找不到藍色格（previewTile1）")
            return
        }
        guard let green = measureTileExtent(matching: isGreenTestColor, approxRowY: approxRowY, in: context) else {
            XCTFail("水平／垂直掃描找不到綠色格（previewTile2）")
            return
        }

        assertUniformWidthsWithGaps(orange: orange, blue: blue, green: green)
        assertSquareTiles(orange: orange, blue: blue, green: green)
        let cardRightEdge = context.screenWidth - screenPad
        XCTAssertLessThanOrEqual(orange.maxX, cardRightEdge, "previewTile0 右緣超出卡片邊界")
        XCTAssertLessThanOrEqual(blue.maxX, cardRightEdge, "previewTile1 右緣超出卡片邊界")
        XCTAssertLessThanOrEqual(green.maxX, cardRightEdge, "previewTile2 右緣超出卡片邊界")
    }

    /// 同列三格寬度要互相相等，且彼此之間要有非測試色的間距（`AppSpacing.label`）——
    /// a356f033 量到「同列寬度不等、零間距」正對應這兩條。
    private func assertUniformWidthsWithGaps(orange: TileExtent, blue: TileExtent, green: TileExtent) {
        XCTAssertEqual(
            orange.width, blue.width, accuracy: 3.0,
            "previewTile0 實際畫出來的寬 \(fmt(orange.width))pt 與 previewTile1 的 \(fmt(blue.width))pt 不相等"
                + "——a356f033 量到的缺陷：測試組 A 三格寬互不相等（91/124/99pt）"
        )
        XCTAssertEqual(
            blue.width, green.width, accuracy: 3.0,
            "previewTile1 實際畫出來的寬 \(fmt(blue.width))pt 與 previewTile2 的 \(fmt(green.width))pt 不相等"
        )
        XCTAssertLessThan(
            orange.maxX, blue.minX,
            "previewTile0（橙）與 previewTile1（藍）之間沒有可見間距（零間距，a356f033 缺陷之一）"
        )
        XCTAssertLessThan(blue.maxX, green.minX, "previewTile1（藍）與 previewTile2（綠）之間沒有可見間距")
    }

    /// 每格寬高相等（正方形）——這正是 `.clipped()` 修復要保證的事（真圖用
    /// `.scaledToFill()` 蓋滿但沒裁時，直式圖會把 tile 往上下撐出格子，見
    /// `DiaryCardView.previewThumbnail` 文件註解）。
    private func assertSquareTiles(orange: TileExtent, blue: TileExtent, green: TileExtent) {
        XCTAssertEqual(
            orange.width, orange.height, accuracy: 3.0,
            "previewTile0 實際畫出來的寬 \(fmt(orange.width))pt／高 \(fmt(orange.height))pt 不是正方形"
        )
        XCTAssertEqual(
            blue.width, blue.height, accuracy: 3.0,
            "previewTile1 實際畫出來的寬 \(fmt(blue.width))pt／高 \(fmt(blue.height))pt 不是正方形——"
                + "a356f033 量到的缺陷：真圖用 `.scaledToFill()` 蓋滿提案但沒有 `.clipped()`，"
                + "直式縮圖（235×512）會照自己的長寬比撐開，不是固定 `previewTileSize` 正方"
        )
        XCTAssertEqual(
            green.width, green.height, accuracy: 3.0,
            "previewTile2 實際畫出來的寬 \(fmt(green.width))pt／高 \(fmt(green.height))pt 不是正方形"
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

/// 讀出來的一個像素 RGB 值——用具名 struct 取代 3-member tuple（SwiftLint
/// `large_tuple` 上限是 2 個成員）。
private struct PixelColor {
    let red: Int
    let green: Int
    let blue: Int
}

/// 一個測試色實際畫在螢幕上的範圍（`measureTileExtent` 的回傳值）。
private struct TileExtent {
    let width: CGFloat
    let height: CGFloat
    let minX: CGFloat
    let maxX: CGFloat
}

/// `measureTileExtent` 掃描需要的環境（截圖像素讀取器＋座標換算＋螢幕尺寸）——包成一個
/// struct 是因為 SwiftLint `function_parameter_count` 上限是 5 個參數，散裝傳法會超過。
private struct ScanContext {
    let reader: PixelReader
    let scale: CGFloat
    let screenWidth: CGFloat
    let screenHeight: CGFloat
}

/// 三張測試圖的字面色（`TapTargetGateHarness.diaryCardVideoBadgesHost` 呼叫
/// `makeTestImageURL` 時給的 RGB 值），容差蓋掉 JPEG 壓縮／螢幕取樣的個位數誤差。
private func isOrangeTestColor(_ color: PixelColor) -> Bool {
    color.red > 220 && color.green > 100 && color.green < 160 && color.blue < 40
}

private func isBlueTestColor(_ color: PixelColor) -> Bool {
    color.red < 40 && color.green > 80 && color.green < 130 && color.blue > 220
}

private func isGreenTestColor(_ color: PixelColor) -> Bool {
    color.red < 40 && color.green > 180 && color.blue > 30 && color.blue < 90
}

/// 在 `approxRowY` 這條橫線上水平掃描找出符合 `matching` 的像素範圍，取範圍中點再垂直
/// 掃描一次找出高度——回傳「畫出來的像素」實際佔用的寬高與水平邊界，不透過任何呼叫端
/// 宣稱的 `XCUIElement.frame`（見 `testPreviewTiles_sameRowUniformSquares_withinCardBounds`
/// 文件註解，`.frame` 量不到這類缺陷）。
private func measureTileExtent(
    matching colorTest: (PixelColor) -> Bool, approxRowY: CGFloat, in context: ScanContext
) -> TileExtent? {
    var horizontalRange: (min: CGFloat, max: CGFloat)?
    var scanX: CGFloat = 0
    while scanX < context.screenWidth {
        if let color = context.reader.color(pointX: scanX, pointY: approxRowY, scale: context.scale),
            colorTest(color) {
            horizontalRange = (min(horizontalRange?.min ?? scanX, scanX), max(horizontalRange?.max ?? scanX, scanX))
        }
        scanX += 1
    }
    guard let horizontal = horizontalRange else { return nil }

    let midX = (horizontal.min + horizontal.max) / 2
    var verticalRange: (min: CGFloat, max: CGFloat)?
    var scanY: CGFloat = 0
    while scanY < context.screenHeight {
        if let color = context.reader.color(pointX: midX, pointY: scanY, scale: context.scale), colorTest(color) {
            verticalRange = (min(verticalRange?.min ?? scanY, scanY), max(verticalRange?.max ?? scanY, scanY))
        }
        scanY += 1
    }
    guard let vertical = verticalRange else { return nil }

    return TileExtent(
        width: horizontal.max - horizontal.min + 1, height: vertical.max - vertical.min + 1,
        minX: horizontal.min, maxX: horizontal.max
    )
}

/// 讀 `UIImage`／`CGImage` 指定座標像素的 RGB 值——把整張圖畫進一個自訂 `CGContext`
/// （明確指定 `premultipliedLast`＝RGBA 順序），一次性取得整張圖的原始 byte buffer，
/// 之後每次查詢都是直接陣列索引，不必每個像素各開一個 context（效能與正確性都比對
/// `CGImage.dataProvider` 原生 byte layout 猜 byte order 可靠——不同 iOS 版本／
/// 截圖來源的原生格式不保證一致，自訂 context 才能鎖定已知格式）。
private final class PixelReader {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let bytesPerPixel = 4

    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // `CGContext` 的 data pointer 只在 `withUnsafeMutableBytes` 閉包內保證有效——
        // 建立 context 與畫圖都要在同一個閉包裡做完，不能把 context 帶出閉包外才呼叫
        // `.draw(...)`（那樣底層 pointer 可能已經失效）。
        let didDraw = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = buffer
    }

    /// `pointX`／`pointY` 是 UIKit points（跟 `XCUIElement.frame` 同一套座標），`scale` 用
    /// `UIImage.scale`（螢幕實際 pixel 密度）換算成像素索引。
    func color(pointX: CGFloat, pointY: CGFloat, scale: CGFloat) -> PixelColor? {
        let pixelX = Int((pointX * scale).rounded())
        let pixelY = Int((pointY * scale).rounded())
        guard pixelX >= 0, pixelY >= 0, pixelX < width, pixelY < height else { return nil }
        let offset = pixelY * bytesPerRow + pixelX * bytesPerPixel
        return PixelColor(red: Int(pixels[offset]), green: Int(pixels[offset + 1]), blue: Int(pixels[offset + 2]))
    }
}
