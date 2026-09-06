import XCTest

/// LS-193：04a／04d／04e 刪除帳號流程 AX3 動態字級——共用 `TapTargetMeasurement.launch(_:
/// contentSizeCategory:)`。AX 字級一律走 `launchArguments`（LS-211；LS-190 R2 已修正該共用
/// helper，見該檔文件註解——啟動參數傳遞方式選錯會讓 app 其實一直跑在標準字級，斷言只是恰好
/// 在標準字級下也成立，AX5 情境下量到的高度會跟完全沒設定時一樣，改對通道才真的放大）。
///
/// 每一支測試都先驗證「字級真的放大」（比較同一個 sentinel 文字節點在一般字級與 AX3 下的
/// frame 高度，量到明顯差異才代表字級真的生效），再驗證按鈕 hit-test 仍 ≥44pt——沒有這道
/// 前置斷言，字級設定若因為某種原因失效，量測會落回一般字級、誤判「AX3 下沒問題」。
@MainActor
final class DeleteAccountFlowAX3UITests: XCTestCase {
    // AX3＝`.accessibilityExtraLarge`——內部字串是縮寫形式（同 `TapTargetMeasurement.launch`
    // 既有用法 `"UICTContentSizeCategoryL"`，不是拼出全字的 "Large"）：XS/S/M/L/XL/XXL/XXXL，
    // 一般字級套用「Accessibility」前綴對應 AX1–AX5。實測釘住：一開始誤用拼字全稱
    // "AccessibilityExtraLarge" 時 UIKit 靜默忽略、量到跟未設定時完全相同的高度（40.67pt＝
    // 40.67pt），改用這個縮寫字串後才量到真的放大。
    private static let ax3Category = "UICTContentSizeCategoryAccessibilityXL"
    private static let defaultCategory = "UICTContentSizeCategoryL"

    /// 量一般字級下 sentinel 的高度，供跟 AX3 比對——用完就關閉，避免兩個 app 行程並存。
    private func measureDefaultHeight(
        screen: TapTargetGateScreenName, sentinelText: String, file: StaticString = #filePath, line: UInt = #line
    ) -> CGFloat {
        let app = TapTargetMeasurement.launch(screen, contentSizeCategory: Self.defaultCategory)
        TapTargetMeasurement.assertScreenRendered(screen, in: app, file: file, line: line)
        let height = app.staticTexts[sentinelText].frame.height
        app.terminate()
        return height
    }

    private func assertEnlargedAndTappable(
        screen: TapTargetGateScreenName, sentinelText: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let defaultHeight = measureDefaultHeight(screen: screen, sentinelText: sentinelText, file: file, line: line)

        let ax3App = TapTargetMeasurement.launch(screen, contentSizeCategory: Self.ax3Category)
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
