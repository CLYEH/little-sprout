#if DEBUG
/// LS-95：≥44pt 點擊目標機械 gate 用的畫面選擇鍵值。
///
/// XCUITest 跑在跟被測 app 分離的獨立行程，`LittleSproutUITests` 沒辦法 `import LittleSprout`
/// 直接引用 app target 的型別（跟 `LittleSproutTests` 這種同行程的 unit test 不一樣）——兩邊
/// 只能靠字串常數溝通：app 這邊（`TapTargetGateHarness.swift`）讀 launch environment 決定顯示
/// 哪個畫面，UI test 那邊寫入同一個字串當作 launch environment 值。這份 rawValue 定義因此同時
/// 被兩個 target 的 sources 收錄（見 project.yml），值只需要改一處。
///
/// merge-review R1 I1：整支 `#if DEBUG` 圍住——本來沒有圍欄，Release build 會編進一個永遠用
/// 不到的 enum（`TapTargetGateHarness` 已經整支 `#if DEBUG`，只在 DEBUG 引用它）。兩個 target
/// 的 Debug 組建都定義了 `DEBUG`（`xcodebuild -showBuildSettings` 實測 `LittleSproutUITests`
/// 的 Debug 組態一樣有 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`，繼承自 project 層級），
/// 加圍欄不影響 UI test target 編譯。
enum TapTargetGateScreenName: String {
    case otpVerification = "OTPVerificationView"
    case settings = "SettingsView"

    // 自測樣本（LS-95 自己的 gate 自測，不是產品畫面）：`TapTargetGateSelfTests` 專用。
    case selfTestTooSmall = "SelfTestTooSmall"
    case selfTestGood = "SelfTestGood"
    // #148 R1 I4 的漏網型：padding 掛在外層容器、不是掛在 Button 的 label／contentShape
    // 鏈上——這是 LS-95 存在的理由，這個樣本測不出來就代表整支 gate 白做。
    case selfTestPaddingOutsideButton = "SelfTestPaddingOutsideButton"

    /// merge-review R1 B1：harness 一旦沒有真的渲染出這個畫面（環境變數鍵值走鐘、
    /// `TapTargetGateHarness.hostView(for:)` 某個 case 回傳空內容、未來啟動流程在
    /// `RootView` 之前插入攔截畫面），量測會變成「0 個元件＝0 個違規＝綠」靜默通過——
    /// reviewer 實測：把環境變數鍵名打錯，兩條產品畫面檢查照樣全綠。每個畫面在渲染成功時
    /// 必定存在的一個 accessibility 元素當 sentinel，`TapTargetMeasurement` 啟動後先斷言它
    /// 存在，斷言失敗就代表 harness 沒生效，而不是「這個畫面剛好沒有按鈕」。
    var sentinel: TapTargetGateSentinel {
        switch self {
        case .otpVerification: return .staticText("輸入驗證碼")
        case .settings: return .button("登出")
        case .selfTestTooSmall: return .button("小按鈕")
        case .selfTestGood: return .button("好按鈕")
        case .selfTestPaddingOutsideButton: return .button("小按鈕")
        }
    }
}

/// 純資料——不依賴 XCTest／XCUIElement，兩個 target 都能編（app target 不需要用到它，但
/// `TapTargetGateScreenName` 統一放在共用檔案，簡單起見不另外拆檔）。實際查詢邏輯（怎麼從
/// `XCUIApplication` 找到對應元素）在 `LittleSproutUITests/TapTargetMeasurement.swift`。
enum TapTargetGateSentinel {
    case staticText(String)
    case button(String)

    var description: String {
        switch self {
        case .staticText(let text): return "staticText[\(text)]"
        case .button(let label): return "button[\(label)]"
        }
    }
}
#endif
