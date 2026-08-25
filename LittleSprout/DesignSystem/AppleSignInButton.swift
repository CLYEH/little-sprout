import AuthenticationServices
import SwiftUI

/// `cmp/Button Apple`：官方樣式（`.black`／深色 `.white`）是品牌硬規定，實作務必用官方
/// `SignInWithAppleButton`（Handoff Notes「三方登入鍵的色彩豁免」）——不得自畫黑底白字鈕。
///
/// 官方元件的文案（「透過 Apple 登入」）與圖示由系統依裝置語系決定，無法換成設計稿上的
/// 自訂中文「使用 Apple 登入」／「登入中…」（Apple API 沒有開放客製文字）。01b 的「登入中」
/// 態改用同尺寸、同底色的疊層蓋住官方按鈕顯示 spinner＋文字，維持官方元件在非 in-flight
/// 狀態下始終是唯一可互動的層——不是繞過官方元件重畫一顆假的。
///
/// **已知限制**：Sign in with Apple entitlement 依賴 LS-8（Apple Developer Program，尚未
/// 完成），本機／模擬器沒有 capability 時點下去會拿到系統層的授權錯誤，是預期中的阻塞，
/// 不是這裡的邏輯錯誤（`AppleSignInNonce.swift` 已有相同前提說明）。
///
/// **已知限制（R3 review A2）**：`SignInWithAppleButton` 包的 `ASAuthorizationAppleIDButton`
/// 標題字級由系統依按鈕高度等比推導，本身不吃 Dynamic Type——AX3 實測（iPhone 17 Pro
/// 模擬器，iOS 26）鈕高固定在 56pt，與一般字級完全相同；同畫面的 Google／Email 鍵在 AX3
/// 分別長到 119pt／79pt（見 `.claude/evidence/LS-17/r3/01-welcome-ax3-iphone17pro.png`）。
/// 這是系統元件的限制，不是這裡漏做 `minHeight`——Apple 官方規範要求使用官方按鈕、不得
/// 換皮／自繪，56pt 仍遠高於 44pt 可點擊標準，接受凍結在 56pt。
struct AppleSignInButton: View {
    let isSigningIn: Bool
    let onRequest: (ASAuthorizationAppleIDRequest) -> Void
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SignInWithAppleButton(.signIn, onRequest: onRequest, onCompletion: onCompletion)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(minHeight: 56)
                .disabled(isSigningIn)
                .opacity(isSigningIn ? 0 : 1)
                .accessibilityHidden(isSigningIn)

            if isSigningIn {
                HStack(spacing: AppSpacing.label) {
                    ProgressView().tint(Color.lsAppleForeground)
                    Text("登入中…").appFont(.body).foregroundStyle(Color.lsAppleForeground)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 56)
                .background(Color.lsAppleBackground, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在使用 Apple 登入")
            }
        }
    }
}
