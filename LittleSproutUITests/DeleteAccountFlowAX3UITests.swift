import XCTest

/// LS-193：04a／04d／04e 刪除帳號流程 AX3 動態字級——`-UIPreferredContentSizeCategoryName`
/// 一律用 `launchArguments`，不用 `launchEnvironment`（LS-210 merge-review 實測：
/// `app.launchEnvironment["UIPreferredContentSizeCategoryName"]` 對 XCUITest 目標 app 不生效，
/// 見 LS-96 池項 `b63b274a`(a) 的具體量測：AX5 下 env 通道量到 40.67pt＝跟未設定相同，
/// `launchArguments` 通道量到 69.33pt＝真的放大了）。`TapTargetMeasurement.launch(_:)` 目前
/// 仍是舊版 `launchEnvironment` 寫法（LS-190 PR #331 已在 development 修正但尚未併入本票基底
/// commit），這裡不沿用那支共用 helper 測 AX3，改直接手動組 `launchArguments`；`assertScreen
/// Rendered`／`violations(in:)` 兩支純量測函式沒有這個問題，仍可共用。
///
/// 每一支測試都先驗證「字級真的放大」（比較同一個 sentinel 文字節點在一般字級與 AX3 下的
/// frame 高度，量到明顯差異才代表 launch argument 真的生效），再驗證按鈕 hit-test 仍
/// ≥44pt——沒有這道前置斷言，`launchArguments` 若因為某種原因失效，量測會落回一般字級、
/// 誤判「AX3 下沒問題」。
@MainActor
final class DeleteAccountFlowAX3UITests: XCTestCase {
    // AX3＝`.accessibilityExtraLarge`——內部字串是縮寫形式（同 `TapTargetMeasurement.launch`
    // 既有用法 `"UICTContentSizeCategoryL"`，不是拼出全字的 "Large"）：XS/S/M/L/XL/XXL/XXXL，
    // 一般字級套用「Accessibility」前綴對應 AX1–AX5。實測釘住：一開始誤用拼字全稱
    // "AccessibilityExtraLarge" 时 UIKit 靜默忽略、量到跟未設定時完全相同的高度（40.67pt＝
    // 40.67pt），改用這個縮寫字串後才量到真的放大（見下方 `test...` 的斷言與其失敗紀錄）。
    private static let ax3Category = "UICTContentSizeCategoryAccessibilityXL"

    private func launch(screen: TapTargetGateScreenName, contentSizeCategory: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = screen.rawValue
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        return app
    }

    /// 量一般字級下 sentinel 的高度，供跟 AX3 比對——用完就關閉，避免兩個 app 行程並存。
    private func measureDefaultHeight(
        screen: TapTargetGateScreenName, sentinelText: String, file: StaticString = #filePath, line: UInt = #line
    ) -> CGFloat {
        let app = launch(screen: screen, contentSizeCategory: nil)
        TapTargetMeasurement.assertScreenRendered(screen, in: app, file: file, line: line)
        let height = app.staticTexts[sentinelText].frame.height
        app.terminate()
        return height
    }

    private func assertEnlargedAndTappable(
        screen: TapTargetGateScreenName, sentinelText: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let defaultHeight = measureDefaultHeight(screen: screen, sentinelText: sentinelText, file: file, line: line)

        let ax3App = launch(screen: screen, contentSizeCategory: Self.ax3Category)
        TapTargetMeasurement.assertScreenRendered(screen, in: ax3App, file: file, line: line)
        let ax3Height = ax3App.staticTexts[sentinelText].frame.height
        XCTAssertGreaterThan(
            ax3Height, defaultHeight * 1.3,
            "AX3 launchArguments 應該讓「\(sentinelText)」明顯放大" +
            "（一般 \(defaultHeight)pt → AX3 \(ax3Height)pt）——沒有放大代表 launchArguments 沒生效，量測毫無意義",
            file: file, line: line
        )

        for message in TapTargetMeasurement.violations(in: ax3App) {
            XCTFail(message, file: file, line: line)
        }
    }

    func testGeneralMemberView_ax3_titleEnlarges_buttonsStayTappable() {
        assertEnlargedAndTappable(screen: .deleteAccountGeneralMember, sentinelText: "刪除帳號")
    }

    func testSoleMemberWarningView_ax3_warningLabelEnlarges_buttonsStayTappable() {
        assertEnlargedAndTappable(screen: .deleteAccountSoleMember, sentinelText: "你是這個家庭唯一的成員")
    }

    func testFinalConfirmView_ax3_titleEnlarges_buttonsStayTappable() {
        assertEnlargedAndTappable(screen: .deleteAccountFinalConfirm, sentinelText: "最後確認")
    }
}
