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
