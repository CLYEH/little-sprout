/// `WelcomeView` 三顆登入鈕（Apple／Google／Email）互斥狀態的純值計算（R1 review F1，
/// PR #163）：任一方式在跑，另外兩顆要暫時 disable，但**只有自己在跑的那顆**才顯示
/// in-flight 疊層／文案——原 bug 是 `AppleSignInButton` 只吃 Apple 自己的旗標，Google
/// 在跑時 Apple 鈕仍可按，兩條登入流程能並行寫入 `AuthStore.session`。
///
/// 抽成獨立、可測試的純值型別，而不是把布林運算散在 `WelcomeView` body 裡：專案沒有
/// ViewInspector 依賴，View 層邏輯不可測，這裡把「誰要 disable」「誰顯示 in-flight」
/// 「狀態插槽該顯示什麼文案」全部集中成純函式，才能單元測試釘住（見 review I2 建議、
/// `AuthButtonsStateTests.swift`）。
struct AuthButtonsState {
    let isSigningInWithApple: Bool
    let isSigningInWithGoogle: Bool

    /// Apple 鈕是否顯示官方鈕的「登入中…」疊層：只反映 Apple 自己，不受 Google 影響。
    var appleShowsInFlight: Bool { isSigningInWithApple }

    /// Apple 鈕是否暫時不可按：自己在跑，或 Google 在跑（互斥，F1 根因）。
    var appleIsDisabled: Bool { isSigningInWithApple || isSigningInWithGoogle }

    /// Google 鈕暗化狀態（既有：`GoogleSignInButton.isDimmed` 同時控制外觀與 `.disabled`）。
    var googleIsDimmed: Bool { isSigningInWithApple || isSigningInWithGoogle }

    /// Email 鈕暗化狀態，同上。
    var emailIsDimmed: Bool { isSigningInWithApple || isSigningInWithGoogle }

    /// 法務／狀態插槽該顯示的文案：任一方式在跑都要給回饋（F1 建議），不是只有 Apple 有——
    /// 否則 Google 面板關閉、PKCE code exchange 仍在跑的那幾秒會三顆鈕全灰卻零提示。
    var statusMessage: String? {
        if isSigningInWithApple { return "正在與 Apple 確認你的身分，請稍候。" }
        if isSigningInWithGoogle { return "正在與 Google 確認你的身分，請稍候。" }
        return nil
    }
}
