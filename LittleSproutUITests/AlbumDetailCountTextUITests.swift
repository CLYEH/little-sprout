import XCTest

/// LS-407 範圍 3（池 5e2b5013）：相簿詳情頁張數節點與卡片 `captionText` 同源，逐字元帶 LS-388 折行字元——
/// 數字與「張」之間 U+00A0、「張相片」字間 U+2060（稿面 `MIxHp`）。改前是 `"\(N) 張相片"` 普通空白。
/// accessibility label 會把 U+2060 濾掉（實測只剩 U+00A0），所以這裡只驗數字後的 NBSP；U+2060 的位置由
/// `AlbumSignatureFormatterTests.test_countText_breakCharactersAtExactPositions` 逐字元釘住。
@MainActor
final class AlbumDetailCountTextUITests: XCTestCase {
    func testDetailCountText_usesSameBreakCharactersAsCardCaption() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = TapTargetGateScreenName.albumDetailPopulated.rawValue
        app.launchWithRetry()
        // `AlbumDetailScreenshotAPIClient(photoCount: 12)`：張數 Text 是畫面上唯一含「張」的靜態文字。
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "張")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "相簿詳情頁沒有含「張」的張數節點")
        let scalars = count.label.unicodeScalars.map { String(format: "U+%04X", $0.value) }
        XCTAssertEqual(
            count.label, "12\u{00A0}張相片",
            "詳情頁張數應為「12<NBSP>張相片」（a11y label 已濾掉 U+2060），實際字元＝\(scalars.joined(separator: " "))"
        )
    }
}
