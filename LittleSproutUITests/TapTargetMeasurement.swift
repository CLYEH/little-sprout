import XCTest

/// LS-95 共用量測邏輯：`TapTargetGateTests`（正式畫面）與 `TapTargetGateSelfTests`（自測樣本）
/// 都靠它——「怎麼判定違規」只有一份實作，兩邊不會各自長出一套判斷邏輯而互相漂移。
@MainActor
enum TapTargetMeasurement {
    static let minSide: CGFloat = 44

    /// 啟動 app 到指定畫面（見 `TapTargetGateScreenName`／`TapTargetGateHarness`），固定一般
    /// 字級（非 AX 放大字級）——#148 R1 F2：放大字級下內容本身就會 ≥44pt，量了無意義。
    static func launch(_ screen: TapTargetGateScreenName) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = screen.rawValue
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryL"
        app.launch()
        return app
    }

    /// 逐一檢查畫面上每個 Button／tappable 元件的 accessibility frame，回傳所有 <44pt 的違規
    /// 描述——不因為找到第一個違規就提前結束（LS-86 retro：全域條件不能遮蔽個別判定路徑），
    /// 讓呼叫端能一次點名所有違規者，不是只抓到第一個。
    static func violations(in app: XCUIApplication) -> [String] {
        var found: [String] = []
        for element in app.buttons.allElementsBoundByIndex {
            let frame = element.frame
            guard frame.width < minSide || frame.height < minSide else { continue }
            let label = element.label.isEmpty ? "(無 label)" : element.label
            found.append(
                "TAP-TARGET-FAIL: \(label) frame=\(format(frame.width))x\(format(frame.height))pt"
                    + "（需 ≥\(Int(minSide))×\(Int(minSide))pt）"
            )
        }
        return found
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}
