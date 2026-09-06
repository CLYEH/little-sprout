import XCTest

/// LS-95 共用量測邏輯：`TapTargetGateTests`（正式畫面）與 `TapTargetGateSelfTests`（自測樣本）
/// 都靠它——「怎麼判定違規」只有一份實作，兩邊不會各自長出一套判斷邏輯而互相漂移。
@MainActor
enum TapTargetMeasurement {
    static let minSide: CGFloat = 44

    /// 啟動 app 到指定畫面（見 `TapTargetGateScreenName`／`TapTargetGateHarness`），固定一般
    /// 字級（非 AX 放大字級）——#148 R1 F2：放大字級下內容本身就會 ≥44pt，量了無意義。
    static func launch(_ screen: TapTargetGateScreenName) -> XCUIApplication {
        launch(screen, contentSizeCategory: "UICTContentSizeCategoryL")
    }

    /// LS-190 R2（merge-review R1 B1）：帶指定字級啟動——`DeleteConfirmationSheetAX3UITests`
    /// 需要在 AX3（`accessibility-extra-large`）下斷言確認文案完整可達，這支 gate 原本只有
    /// 一般字級這個固定通道。既有呼叫端（`launch(_:)`）行為不變。字級常數見
    /// `UIContentSizeCategory`：AX1–AX5 依序是 `UICTContentSizeCategoryAccessibilityM／L／
    /// XL／XXL／XXXL`，AX3＝`...AccessibilityXL`。
    ///
    /// **LS-190 R2 追加修正（LS-210 merge-review R1 comment `24fc12db` i3）**：原本用
    /// `app.launchEnvironment["UIPreferredContentSizeCategoryName"]` 設字級——這個鍵是 UIKit
    /// 啟動時讀 `NSUserDefaults`（`NSArgumentDomain`）才會生效的鍵，只設 process 環境變數不會被
    /// UIKit 讀到，等於完全沒效果（reviewer 實測：probe 量「設定」標題高度，設 AX5 環境變數跟
    /// 完全不設是同一個值 40.67pt；改成 `launchArguments` 的 `-KEY VALUE` 命令列參數形式才會
    /// 真的放大到 69.33pt）。改用 `launchArguments`：`XCUIApplication.launch()` 會把它們原樣
    /// 傳給啟動的行程，UIKit 在啟動時直接讀命令列參數寫入 `NSArgumentDomain`，這是系統
    /// 支援命令列覆寫使用者設定的既有機制，不需要 app 自己的程式碼配合解析。
    static func launch(_ screen: TapTargetGateScreenName, contentSizeCategory: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LS_TAP_TARGET_GATE_SCREEN"] = screen.rawValue
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        app.launch()
        return app
    }

    /// merge-review R1 B1 必修：斷言畫面真的渲染出對應的 sentinel 元素，不是靜默 fallback 到
    /// 別的畫面（RootView／WelcomeView 等）。reviewer 實測重現：把
    /// `LS_TAP_TARGET_GATE_SCREEN` 這個環境變數鍵名打錯一個字，`TapTargetGateHarness.activeScreen`
    /// 就會是 nil、app 退回 `RootView`，兩條產品畫面檢查因為「0 個 Button＝0 個違規」照樣全綠。
    /// `file`／`line` 讓斷言失敗時指向呼叫端（測試方法）而不是這支共用檔案，方便直接跳轉。
    static func assertScreenRendered(
        _ screen: TapTargetGateScreenName, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let element = screen.sentinel.element(in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            "\(screen.rawValue) 畫面沒有渲染出 sentinel 元素「\(screen.sentinel.description)」——" +
            "harness 可能沒生效（LS_TAP_TARGET_GATE_SCREEN 鍵值走鐘、hostView 這個 case 回傳空內容、" +
            "或啟動流程被別的畫面攔截，merge-review R1 B1）",
            file: file, line: line
        )
    }

    /// 逐一檢查畫面上每個 Button／tappable 元件的 accessibility frame，回傳所有 <44pt 的違規
    /// 描述——不因為找到第一個違規就提前結束（LS-86 retro：全域條件不能遮蔽個別判定路徑），
    /// 讓呼叫端能一次點名所有違規者，不是只抓到第一個。
    ///
    /// merge-review R1 B1 第二道防線：0 個元件本身就 `XCTFail`（不能只靠 `assertScreenRendered`
    /// 的 sentinel，OTP 畫面的 sentinel 是 staticText，就算它存在也不保證 Button 有渲染出來）。
    static func violations(
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) -> [String] {
        let elements = app.buttons.allElementsBoundByIndex
        XCTAssertFalse(
            elements.isEmpty,
            "畫面沒有任何 Button／tappable 元件——0 個元件會被誤判成 0 個違規＝綠，" +
            "harness 可能沒生效（merge-review R1 B1）",
            file: file, line: line
        )
        var found: [String] = []
        for element in elements {
            let frame = element.frame
            // LS-217 實測踩到：`SettingsView` 加一列（推播通知）之後，清單裡跟它完全無關的
            // 「刪除帳號」列從乾淨的 `44.0` 變成 `43.999999999999886`——量到的是 SwiftUI
            // auto-layout 對一長串非整數高度列（本畫面多個 `$fs-note` 副標列的自然高度是
            // 1/3pt 循環小數，見上面幾列 `65.666...`/`99.999...`）逐一疊加座標時，浮點數
            // 誤差在鏈條夠長時累積出的雜訊，不是這顆按鈕真的縮小了——同一輪 `git stash` 對照
            // 量測（改動前後兩份 dump）確認前後的 x/y/width 分毫不差，只有這個 height 差了
            // `1.14e-13`pt，遠低於任何裝置能渲染出的差異。原本的嚴格 `<` 比較沒有給浮點誤差
            // 留任何餘裕，這張畫面的列數只會隨著票數增加持續往上疊、遲早都會有下一票踩中同一顆
            // 雷；`tolerance` 只吸收這種量級的雜訊，任何真的變小（哪怕只小 0.01pt）依然會被抓到。
            let tolerance: CGFloat = 0.001
            guard frame.width < minSide - tolerance || frame.height < minSide - tolerance else { continue }
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

extension TapTargetGateSentinel {
    /// 從 `XCUIApplication` 找到對應的 sentinel 元素——只有 UI test target 需要這層查詢邏輯
    /// （app target 引用不到 `XCUIElement`），所以這個 extension 放在 `LittleSproutUITests`
    /// 而不是共用檔案。
    @MainActor
    func element(in app: XCUIApplication) -> XCUIElement {
        switch self {
        case .staticText(let text): return app.staticTexts[text]
        case .button(let label): return app.buttons[label]
        }
    }
}
