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
    /// LS-193：04e 最終確認的「輸入『刪除帳號』」欄——沒有固定 label（同 `LabeledTextField`
    /// 慣例，見 `DeleteAccountFlowView+FinalConfirm.swift`），改用 identifier。
    static let deleteAccountConfirmField = "qa.deleteAccount.confirmField"
    /// LS-216：時間軸卡片互動列（`InteractionRow`）三顆按鈕的 identifier——三種卡片
    /// （diary／album／media）在同一頁可能同時顯示相同文字（例如都還沒有人留言時都是
    /// 「留言，0 則」），靠 label 分不出「這是哪張卡的按鈕」，改用依 `kind` 區分的
    /// identifier。`kind`／`element` 都傳純字串（不是 app target 的 `FeedKind`）——
    /// `LittleSproutUITests` 引用不到 app target 的型別，同本檔既有的字串共用慣例。
    static func interactionRowElement(kind: String, element: String) -> String {
        "qa.interactionRow.\(kind).\(element)"
    }
    /// LS-217：01 設定頁「推播通知」列——`value`（「開啟」／「關閉」）隨
    /// `UNAuthorizationStatus` 而變，同 `settingsStorageRow` 的既有理由改用 identifier。
    static let settingsPushRow = "qa.settings.pushRow"
    /// LS-217 QA R1 FAIL（Linear comment `e4863482`）修正：`PushPrepromptView` 的「稍後再說」
    /// 按鈕——`QADriver.dismissPushPrepromptIfPresent()` 靠它判定登入後首次進時間軸的推播前置
    /// 頁是否出現並點掉。文案本身穩定（不像 `settingsStorageRow` 那樣會隨狀態變），仍改用
    /// identifier 而非明碼比對：`QADriver` 其餘畫面共用「新增回憶」「之後再說」這類明碼慣例
    /// 是因為那些文案不會跟別的畫面撞名，但這裡刻意留一個機械可辨識、不受未來文案調整影響的
    /// 錨點（同檔案既有慣例：只放「靠 label 找不穩」或需要穩定性保證的元件）。
    static let pushPrepromptSkipButton = "qa.pushPreprompt.skipButton"
    /// LS-218：留言 sheet 輸入列——`TextField`／送出鈕文案固定（皆「留言...」／icon-only），
    /// 不需要靠 identifier 分辨「哪一個」，只是同 `diaryBodyEditor` 既有理由改用 identifier
    /// （欄位靠 label 找不穩）。
    static let commentInputField = "qa.comments.inputField"
    static let commentSendButton = "qa.comments.sendButton"
    /// 留言列——同 `interactionRowElement` 理由，多則留言可能有相同作者／相對時間文字（例如
    /// 都是「剛剛」），改用依 `id` 區分的 identifier。
    static func commentRow(id: String) -> String { "qa.comments.row.\(id)" }
    static let commentLoadEarlierButton = "qa.comments.loadEarlierButton"
    static let commentRetryButton = "qa.comments.retryButton"
    static let commentCloseButton = "qa.comments.closeButton"
}
