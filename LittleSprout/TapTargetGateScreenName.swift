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
    // merge-review R1 M5：`DiaryEditorView` 原本具名排除在 tap-target-exemptions.txt，理由
    // 「多步驟表單流程」不成立——初始態不需要任何 seeding（`PreviewDiaryAPIClient`／
    // `PreviewMediaUploadService` 已經是 `#Preview` 在用的假 client，`ChildrenStore.preview()`
    // 同理），初始態本身就有 5 顆可點元件會被量到（取消鈕／新增照片 cell／日期欄位／歸屬欄位／
    // 發佈鈕）——改註冊進 harness，讓這個畫面之後的回歸能被機械 gate 抓到。
    case diaryEditor = "DiaryEditorView"
    // LS-126 delta 復審 m2：`TimelineView` 整體仍在 `tap-target-exemptions.txt`（日分組卡片／
    // 捲底載入需要多筆假資料與捲動狀態才有代表性）——但 Header 停靠的「新增回憶」建立鈕不看
    // 任何 feed 資料，`.preview()` 空狀態就會渲染，是這個畫面唯一「不需要 seed 就有代表性」
    // 的可點元件，量測成本低，值得單獨拉一個 case 出來蓋。
    case timelineDefaultState = "TimelineViewDefaultState"
    /// merge-review `443ec21a` §3：不是點擊目標測試，是借用同一套「launch environment 指定
    /// 畫面」機制餵 `DiaryCardVideoBadgeGeometryTests` 量真實 frame（a11y tree 讀得出文字，
    /// 讀不出像素——這正是本輪 FAIL 的根因，見該測試檔文件註解）。沿用這裡而不是另開一套
    /// 平行機制：兩個 target 之間本來就只有這一條「XCUITest 指定畫面」通道。
    case diaryCardVideoBadges = "DiaryCardVideoBadges"

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
        case .diaryEditor: return .staticText("寫日記")
        case .timelineDefaultState: return .button("新增回憶")
        case .diaryCardVideoBadges: return .staticText("影片 12:34")
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
