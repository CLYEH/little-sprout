/// LS-158：QA 端到端情境測試（`LittleSproutUITests/QA/QASmokeTests`）與 app 之間共用的
/// accessibility identifier 常數。
///
/// 同 `TapTargetGateScreenName.swift` 的理由：XCUITest 跑在跟被測 app 分離的獨立行程，
/// `LittleSproutUITests` 不能 `import LittleSprout` 引用 app target 的型別，兩邊只能靠字串常數
/// 溝通——這份檔案同時掛進 `LittleSprout` 與 `LittleSproutUITests` 兩個 target 的 sources
/// （見 project.yml），值只需要改一處。
///
/// 只放「靠 label 找不穩」的元件：文案會隨設計對稿改（LS-125／LS-126 一輪就改了好幾處），
/// 按鈕仍沿用 label（`app.buttons["發佈日記"]`，同既有 `SectionTabBarPushRegressionTests` 慣例），
/// 輸入欄位與卡片改用這裡的 identifier。`accessibilityIdentifier` 不影響 VoiceOver 朗讀的
/// label／value／trait，Release build 帶著也無害，所以不圍 `#if DEBUG`。
enum QAAccessibilityID {
    /// 02 Email 登入的信箱欄（`EmailSignInView` 的 `LabeledTextField`）。
    static let emailField = "qa.emailSignIn.emailField"
    /// LS-164 P1 帳號密碼登入的信箱欄（`PasswordSignInView` 的 `LabeledTextField`）。
    static let passwordSignInEmailField = "qa.passwordSignIn.emailField"
    /// LS-164 P1 帳號密碼登入的密碼欄（`PasswordSignInView` 的 `LabeledTextField`）。
    static let passwordSignInPasswordField = "qa.passwordSignIn.passwordField"
    /// 03 六格驗證碼欄（`OTPCodeField` 整列是單一 accessibility element，見該檔）。
    static let otpCodeField = "qa.otp.codeField"
    /// 05 建立家庭的家庭名稱欄。
    static let familyNameField = "qa.createFamily.nameField"
    /// 12 日記編輯器的內文 `TextEditor`。
    static let diaryBodyEditor = "qa.diaryEditor.body"
    /// 時間軸日記卡（`TimelineView` 包 `DiaryCardView` 的 `NavigationLink`——整張卡合併成一顆 button）。
    static let timelineDiaryCard = "qa.timeline.diaryCard"
    /// 13 日記詳情的內文。
    static let diaryDetailBody = "qa.diaryDetail.body"
    /// LS-188：01 設定頁「個人」列（`SettingsView` 包 `ProfileSummaryRow` 的
    /// `NavigationLink`）——垂直置中 UITest 用這支拿到整列的 frame，跟列內「編輯顯示名稱與
    /// 頭像」副標的 frame 比對中線。
    static let settingsProfileRow = "qa.settings.profileRow"
    /// LS-188：01 設定頁「邀請家人」列——垂直置中 UITest 的單行列樣本（跟上面的「個人」列一起
    /// 覆蓋單行／多行副標兩種情境，使用者 2026-09-05 意見）。
    static let settingsInviteRow = "qa.settings.inviteRow"
    /// LS-188 merge-review R1 m1：01 設定頁「儲存空間」列——`value:` 接上用量摘要後 label 會
    /// 隨 `FamilyStore.quota` 是否載入完成而變（「儲存空間」／「儲存空間、2.1／5 GB」），不
    /// 適合再用固定字串比對，改用 identifier。
    static let settingsStorageRow = "qa.settings.storageRow"
}
