import UIKit
import Vision
import XCTest

/// LS-440：`ThumbnailCountLabel`（Notes `sErBN`＋LS-439 `F3GbnN`）在真實 Dynamic Type 下的渲染驗證。
///
/// 單元測試 `ThumbnailCountLabelTests` 量「選了哪一形、寬度有沒有超出可用寬」；但 `Text` 被
/// `lineLimit(1)` 截成「+2…」時 frame 照樣 ≤ 可用寬（`DiaryCardVideoBadgeGeometryTests` 檔頭踩過的
/// 同一個坑），所以這裡對 More Cell 截圖跑 `Vision` OCR，看畫面上**實際畫出來**的字有沒有完整、
/// 有沒有省略號——這是 `minimumScaleFactor` 有沒有生效的唯一像素證據。
///
/// 走 `ThumbnailCountStress` harness（`TapTargetGateHarness+ThumbnailCount.swift`）：64／96 格 × N＝3／28／128，
/// 字級用 launch argument 走真實 Dynamic Type（AX3＝`UICTContentSizeCategoryAccessibilityXL`）。
/// 截圖附在 xcresult（`LS-440-<fixture>-<size>-<scheme>`，`keepAlways`）；設了
/// `LS_440_EVIDENCE_DIR`（`TEST_RUNNER_` 前綴傳入）時另寫一份 PNG 到該目錄供對稿。
@MainActor
final class ThumbnailCountLabelUITests: XCTestCase {
    private static let ax3 = "UICTContentSizeCategoryAccessibilityXL"
    private static let defaultSize = "UICTContentSizeCategoryL"
    /// 左右內距 `$sp-tight`（`AppSpacing.tight`）。UI test 與 app 分離行程，字面值同步寫在這裡。
    private let inset: CGFloat = 6

    func testAX3_64Cell_twoAndThreeDigits_renderCompleteScaledText_insideCell() throws {
        let app = launchStress(size: Self.ax3, scheme: "light")
        for count in [28, 128] {
            let cell = try cell(app, side: 64, count: count)
            let label = try label(in: cell, count: count)
            XCTAssertLessThanOrEqual(
                label.frame.width, cell.frame.width - 2 * inset + 1,
                "AX3 64 格 N=\(count) 標籤寬 \(label.frame.width) 超出可用寬 \(cell.frame.width - 2 * inset)"
            )
            XCTAssertGreaterThanOrEqual(label.frame.minX, cell.frame.minX, "AX3 64 格 N=\(count) 標籤左緣溢出格外")
            XCTAssertLessThanOrEqual(label.frame.maxX, cell.frame.maxX, "AX3 64 格 N=\(count) 標籤右緣溢出格外")
            let recognized = try ocrText(of: cell)
            XCTAssertTrue(
                recognized.contains("\(count)") && recognized.contains("+")
                    && !recognized.contains("…") && !recognized.contains("..."),
                "AX3 64 格 N=\(count) 畫面實際文字為「\(recognized)」，預期完整「+\(count)」、無省略號"
                    + "（short 形被 lineLimit 截斷＝minimumScaleFactor 沒生效）"
            )
        }
        attach(app, name: "LS-440-stress-AX3-light")
    }

    func testAX3_96Cell_threeDigits_scalesAndStaysInsideCell() throws {
        let app = launchStress(size: Self.ax3, scheme: "light")
        let cell = try cell(app, side: 96, count: 128)
        let label = try label(in: cell, count: 128)
        XCTAssertLessThanOrEqual(label.frame.width, cell.frame.width - 2 * inset + 1, "AX3 96 格 +128 溢出可用寬")
        let recognized = try ocrText(of: cell)
        XCTAssertTrue(
            recognized.contains("128") && !recognized.contains("…") && !recognized.contains("..."),
            "AX3 96 格 +128 畫面實際文字為「\(recognized)」，預期完整「+128」"
        )
    }

    func testDefaultSize_longFormWhereItFits_shortElsewhere_voiceOverAlwaysLong() throws {
        let app = launchStress(size: Self.defaultSize, scheme: "light")
        // 96 格 N=3：放得下長形（可用寬 84 ≥ 69）；N=128：89 > 84 退短形（F3GbnN 刻意取捨 MN-8）。
        let long96 = try cell(app, side: 96, count: 3)
        XCTAssertTrue(try ocrText(of: long96).contains("還有"), "96 格 N=3 應顯示長形「還有 3 張」")
        let short96 = try cell(app, side: 96, count: 128)
        XCTAssertFalse(try ocrText(of: short96).contains("還有"), "96 格 N=128 應退短形「+128」")
        // 64 格一律短形。
        let short64 = try cell(app, side: 64, count: 3)
        XCTAssertFalse(try ocrText(of: short64).contains("還有"), "64 格 N=3 應顯示短形「+3」")
        // VoiceOver：不論視覺是哪一形，label 一律長形。
        for (side, count) in [(96, 3), (96, 128), (64, 3), (64, 28)] {
            let cell = try cell(app, side: side, count: count)
            let spoken = try label(in: cell, count: count).label.replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertEqual(spoken, "還有 \(count) 張", "\(side) 格 N=\(count) VoiceOver 應念長形")
        }
        attach(app, name: "LS-440-stress-default-light")
    }

    func testScreenshotMatrix_stressAndDiary() throws {
        for scheme in ["light", "dark"] {
            for (sizeName, size) in [("default", Self.defaultSize), ("AX3", Self.ax3)] {
                attach(launchStress(size: size, scheme: scheme), name: "LS-440-stress-\(sizeName)-\(scheme)")
                let diary = launch(
                    screen: "ThumbnailCountStress", size: size, scheme: scheme,
                    env: ["LS_THUMBNAIL_COUNT_FIXTURE": "diary", "LS_THUMBNAIL_COUNT_REMAINING": "2"]
                )
                XCTAssertTrue(
                    diary.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "還有"))
                        .firstMatch.waitForExistence(timeout: 10),
                    "日記卡第三格暗蓋沒渲染（label 含「還有」）"
                )
                attach(diary, name: "LS-440-diary-\(sizeName)-\(scheme)")
            }
        }
    }

    /// Import 01／06a 真畫面（`ImportOrganizeView`／`...Limited`，群卡縮圖列的 More Cell）。這兩個 host 跟系統外觀
    /// （沒有 `preferredColorScheme`，`-AppleInterfaceStyle` launch argument 在這裡無效，實測），深色截圖要先
    /// `xcrun simctl ui <udid> appearance dark` 再以 `TEST_RUNNER_LS_440_SYSTEM_SCHEME=dark` 跑這支（只影響檔名）。
    func testScreenshotMatrix_importOrganize_followsSystemAppearance() throws {
        let scheme = ProcessInfo.processInfo.environment["LS_440_SYSTEM_SCHEME"] ?? "light"
        for (sizeName, size) in [("default", Self.defaultSize), ("AX3", Self.ax3)] {
            for screen in ["ImportOrganizeView", "ImportOrganizeViewLimited"] {
                let organize = launch(screen: screen, size: size, scheme: "light", env: [:])
                attach(organize, name: "LS-440-\(screen)-\(sizeName)-\(scheme)-top")
                // AX3 下橫幅／標題很高，群卡在首屏以下——往上捲到 More Cell 出現（最多 6 次）。
                let moreCell = organize.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "還有")).firstMatch
                var swipes = 0
                while !moreCell.waitForExistence(timeout: 2) && swipes < 6 {
                    organize.swipeUp()
                    swipes += 1
                }
                XCTAssertTrue(moreCell.exists, "\(screen) \(sizeName)-\(scheme) 找不到 More Cell（label「還有 N 張」）")
                attach(organize, name: "LS-440-\(screen)-\(sizeName)-\(scheme)")
            }
        }
    }

    // MARK: - Helpers

    private func launchStress(size: String, scheme: String) -> XCUIApplication {
        let app = launch(screen: "ThumbnailCountStress", size: size, scheme: scheme, env: [:])
        return app
    }

    private func launch(screen: String, size: String, scheme: String, env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = screen
        app.launchEnvironment["LS_THUMBNAIL_COUNT_SCHEME"] = scheme
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        app.launchWithRetry()
        return app
    }

    private func cell(_ app: XCUIApplication, side: Int, count: Int) throws -> XCUIElement {
        let cell = app.descendants(matching: .any)["thumbnailCount.cell.\(side).\(count)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "找不到 \(side) 格 N=\(count) 的 More Cell 容器")
        return cell
    }

    private func label(in cell: XCUIElement, count: Int) throws -> XCUIElement {
        let label = cell.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "還有")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5), "N=\(count) 的 More Cell 裡找不到 VoiceOver 標籤「還有 N 張」")
        return label
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["LS_440_EVIDENCE_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// 同 `DiaryCardVideoBadgeGeometryTests.ocrText(of:)`：對元件截圖跑 `Vision`，回傳畫面上實際畫出的字。
    private func ocrText(of element: XCUIElement) throws -> String {
        guard let cgImage = element.screenshot().image.cgImage else {
            XCTFail("截圖沒有 cgImage，OCR 無法進行")
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
