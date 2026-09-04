import XCTest

/// LS-158：QA 端到端情境驅動——不依賴 mobile-mcp。
///
/// 來源：LS-129／130 QA（`4cb41a06`／`d731c417`）BLOCKED——mobile-mcp 每次互動把模擬器前景重設回
/// 主畫面（WebDriverAgent session 未沿用），QA 無法多步驟操作 app；同一 build 用 `xcodebuild test
/// -only-testing:LittleSproutUITests` 可正常驅動，證明是工具層。這裡把 QA 最常需要的三條多步驟
/// 路徑寫成可重放的 XCUITest，對**真的本機 Supabase 容器**跑（不是 `TapTargetGateHarness` 那種
/// mock store）：
///
/// - `login`：歡迎頁 → Email → 自 Mailpit 取 6 碼 → 確認登入 → 落點（三岔路或時間軸）。
/// - `publish`：（必要時登入／建立家庭）→ 新增回憶 → 內文 → 相簿選 fixture 照片＋影片 → 發佈 →
///   時間軸出現那張卡。fixture 由 `qa-e2e.sh` 先 `simctl addmedia` 進模擬器相簿。
/// - `browse`：（必要時登入／建立家庭／先發一篇純文字）→ 開日記詳情 → 返回 → 相簿分頁 → 時間軸。
///
/// 怎麼跑：一律 `bash scripts/ops/qa-e2e.sh <login|publish|browse>`（讀 `supabase status`、
/// 持 `supabase-lock.sh --hold`、`-only-testing:LittleSproutUITests/QASmokeTests`、匯出截圖到
/// `.claude/evidence/<票號>/qa-e2e/`、收 Storage log）。直接 `xcodebuild test` 沒帶 `LS_QA_*`
/// 會紅（`QAEnvironment.load`），這是刻意的；CI 只編譯不跑（`tap-target-check.sh` 以
/// `-skip-testing:LittleSproutUITests/QASmokeTests` 排除——`-only-testing` 對 `-skip-testing` 有
/// 優先權，所以那支改成純 `-skip-testing` 組合，見該檔）。
///
/// 每一步 `XCTAttachment` 截圖（`QADriver.snap`）＋以 `QAAccessibilityID`／label 斷言畫面元素；
/// 等不到就附上 a11y 階層再 `XCTFail`，不會靜默跳過。
@MainActor
final class QASmokeTests: XCTestCase {
    override func setUpWithError() throws {
        // 第一個斷言失敗就停：後面每一步都依賴前一步的畫面，繼續跑只會堆出一串無意義的連鎖失敗。
        continueAfterFailure = false
    }

    func testScenario() async throws {
        let env = try QAEnvironment.load()
        let driver = QADriver(env: env, testCase: self)
        switch env.scenario {
        case .login:
            try await driver.runLogin()
        case .publish:
            try await driver.runPublish()
        case .browse:
            try await driver.runBrowse()
        }
    }
}

// MARK: - 三個情境

extension QADriver {
    /// `login` 必須從未登入狀態開始——`qa-e2e.sh` 對這個情境先 `simctl keychain <udid> reset`
    /// 清掉上一輪留下的 session；沒清乾淨就在這裡大聲失敗，不會偷偷改測「已登入」。
    func runLogin() async throws {
        launch()
        guard welcomeEmailButton.waitForExistence(timeout: 10) else {
            attachHierarchy(reason: "login-start")
            snap("fail-not-on-welcome")
            XCTFail("login 情境要從未登入狀態開始，但歡迎頁沒有出現（qa-e2e.sh 對 login 會先 keychain reset）")
            throw QAFailure.screen("歡迎頁")
        }
        snap("welcome")
        try await signInWithEmailOTP()
        try assertLandedAfterLogin()
    }

    func runPublish() async throws {
        try await ensureLoggedIn()
        try ensureFamily()
        try openEditor()
        let body = "LS-158 publish \(Self.stamp())"
        try typeDiaryBody(body)
        try attachFixturesFromPhotoLibrary()
        try publishAndWaitForCard(body: body)
    }

    func runBrowse() async throws {
        try await ensureLoggedIn()
        try ensureFamily()
        try seedDiaryIfTimelineEmpty()
        try browseDetailAndAlbums()
    }
}
