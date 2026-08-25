import AuthenticationServices
@testable import LittleSprout
import XCTest

/// `WelcomeView` 三顆登入鈕互斥邏輯的測試（R1 review F1／I2，PR #163）。
///
/// F1：原 bug 是 `AppleSignInButton` 只吃 Apple 自己的旗標，Google 進行中時 Apple 鈕仍可
/// 按——兩條登入流程能並行寫入 `AuthStore.session`。抽成 `AuthButtonsState`（純值型別）後
/// 這裡直接測那份計算，不靠 ViewInspector（專案沒有這個依賴，見 review I2 建議）。
///
/// I2：Google 登入面板「使用者主動取消」要靜默，這條規則原本整段內嵌在 `WelcomeView.
/// handleGoogleSignIn()` 的 catch 分支裡，零測試覆蓋——被整段誤刪也不會有測試變紅。抽成
/// `WelcomeView.isUserCanceledGoogleSignIn(_:)`（`internal`，可被 `@testable import` 存取）
/// 之後這條判定本身有測試釘住。
///
/// `@MainActor`：`WelcomeView` 是 `View`（`@preconcurrency @MainActor`，見 R1 review 已核對
/// 段），`isUserCanceledGoogleSignIn` 因此也是 MainActor-isolated 靜態方法——同 `OTPVerificationModelTests`
/// 的既有慣例，整個測試類別標 `@MainActor` 才能同步呼叫它，不必逐一補 `await`。
@MainActor
final class AuthButtonsStateTests: XCTestCase {
    // MARK: - F1：Google 進行中時 Apple 鈕 disabled 且不顯示 Apple 自己的「登入中」疊層

    func test_googleInFlight_disablesAppleButNotItsInFlightOverlay() {
        let state = AuthButtonsState(isSigningInWithApple: false, isSigningInWithGoogle: true)

        XCTAssertTrue(
            state.appleIsDisabled,
            "Google 在跑時 Apple 鈕必須暫時不可按，否則兩條登入流程能並行寫入 AuthStore.session"
        )
        XCTAssertFalse(
            state.appleShowsInFlight,
            "Google 在跑不代表 Apple 自己在跑，不能誤顯示 Apple 官方鈕的「登入中」疊層"
        )
    }

    func test_appleInFlight_disablesAppleAndShowsItsOwnOverlay() {
        let state = AuthButtonsState(isSigningInWithApple: true, isSigningInWithGoogle: false)

        XCTAssertTrue(state.appleIsDisabled)
        XCTAssertTrue(state.appleShowsInFlight)
    }

    func test_neitherInFlight_appleEnabledAndNoOverlay() {
        let state = AuthButtonsState(isSigningInWithApple: false, isSigningInWithGoogle: false)

        XCTAssertFalse(state.appleIsDisabled)
        XCTAssertFalse(state.appleShowsInFlight)
    }

    func test_googleAndEmailDimming_matchesExistingBehavior() {
        // Google／Email 兩顆鈕原本就吃 `isSigningInWithApple || isSigningInWithGoogle`，
        // 這條是回歸測試：抽出 AuthButtonsState 不能改變既有正確的那一半行為。
        let bothIdle = AuthButtonsState(isSigningInWithApple: false, isSigningInWithGoogle: false)
        let appleRunning = AuthButtonsState(isSigningInWithApple: true, isSigningInWithGoogle: false)
        let googleRunning = AuthButtonsState(isSigningInWithApple: false, isSigningInWithGoogle: true)

        XCTAssertFalse(bothIdle.googleIsDimmed)
        XCTAssertFalse(bothIdle.emailIsDimmed)
        XCTAssertTrue(appleRunning.googleIsDimmed)
        XCTAssertTrue(appleRunning.emailIsDimmed)
        XCTAssertTrue(googleRunning.googleIsDimmed)
        XCTAssertTrue(googleRunning.emailIsDimmed)
    }

    // MARK: - F1：狀態插槽在 Google 進行中也要給回饋，不能三顆鈕全灰卻零提示

    func test_statusMessage_reflectsWhicheverProviderIsRunning() {
        XCTAssertEqual(
            AuthButtonsState(isSigningInWithApple: true, isSigningInWithGoogle: false).statusMessage,
            "正在與 Apple 確認你的身分，請稍候。"
        )
        XCTAssertEqual(
            AuthButtonsState(isSigningInWithApple: false, isSigningInWithGoogle: true).statusMessage,
            "正在與 Google 確認你的身分，請稍候。",
            "F1：Google 進行中時法務／狀態插槽必須給回饋"
        )
        XCTAssertNil(AuthButtonsState(isSigningInWithApple: false, isSigningInWithGoogle: false).statusMessage)
    }

    // MARK: - I2：取消 Google 登入要靜默（WelcomeView.handleGoogleSignIn 的 catch 分支）

    func test_isUserCanceledGoogleSignIn_trueOnlyForCanceledLoginCode() {
        XCTAssertTrue(WelcomeView.isUserCanceledGoogleSignIn(ASWebAuthenticationSessionError(.canceledLogin)))
    }

    func test_isUserCanceledGoogleSignIn_falseForOtherSessionErrorCodes() {
        XCTAssertFalse(
            WelcomeView.isUserCanceledGoogleSignIn(
                ASWebAuthenticationSessionError(.presentationContextNotProvided)
            ),
            "只有 .canceledLogin 是使用者主動取消，其他 session 錯誤仍要顯示錯誤訊息"
        )
    }

    func test_isUserCanceledGoogleSignIn_falseForUnrelatedErrorTypes() {
        XCTAssertFalse(
            WelcomeView.isUserCanceledGoogleSignIn(AppError.network(message: "offline")),
            "非 ASWebAuthenticationSessionError 的錯誤（例如 PKCE code exchange 失敗）不能被誤判成取消"
        )
    }
}
