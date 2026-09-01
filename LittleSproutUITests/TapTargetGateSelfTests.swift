import XCTest

/// LS-95 自己的 gate 自測（不是產品畫面）：驗證量測機制本身抓得到已知違規、也不會誤判合格
/// 樣本。三條各對應 `TapTargetGateScreenName` 的一個自測樣本，都是「正常情況下必須通過」的
/// 斷言——不是讓 `xcodebuild test` 本身變紅，而是斷言「偵測到的違規數」符合預期，這樣才能跟
/// `TapTargetGateTests`（正式檢查）掛在同一個 `-only-testing:LittleSproutUITests` 底下一起
/// 跑，不會讓每次 UI 票 push 都因為自測樣本本身「故意」不合格而假紅。
///
/// `testPaddingOutsideButtonSampleIsFlagged` 是 #148 R1 I4 的漏網型（padding 掛在 Button
/// 外層、不參與 hit test）——LS-17 QA1 兩顆違規按鈕的原始寫法就是這樣，merge-reviewer 兩輪
/// review 加上 visual-reviewer 五輪對抗迭代都沒攔到。這條測不到就代表整支 gate 白做，是
/// LS-95 存在的理由。
@MainActor
final class TapTargetGateSelfTests: XCTestCase {
    func testTooSmallSampleIsFlagged() {
        let app = TapTargetMeasurement.launch(.selfTestTooSmall)
        TapTargetMeasurement.assertScreenRendered(.selfTestTooSmall, in: app)
        let violations = TapTargetMeasurement.violations(in: app)
        XCTAssertEqual(violations.count, 1, "22×22pt 樣本應該被抓到剛好 1 個違規，實得：\(violations)")
    }

    func testGoodSamplePasses() {
        let app = TapTargetMeasurement.launch(.selfTestGood)
        TapTargetMeasurement.assertScreenRendered(.selfTestGood, in: app)
        let violations = TapTargetMeasurement.violations(in: app)
        XCTAssertTrue(violations.isEmpty, "44×44pt 樣本不應該有違規，實得：\(violations)")
    }

    func testPaddingOutsideButtonSampleIsFlagged() {
        let app = TapTargetMeasurement.launch(.selfTestPaddingOutsideButton)
        TapTargetMeasurement.assertScreenRendered(.selfTestPaddingOutsideButton, in: app)
        let violations = TapTargetMeasurement.violations(in: app)
        XCTAssertEqual(
            violations.count, 1,
            "padding 掛在 Button 外層（不參與 hit test）的漏網型應該被抓到，實得：\(violations)"
        )
    }
}
