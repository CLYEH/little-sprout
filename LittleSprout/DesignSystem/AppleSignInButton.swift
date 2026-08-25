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
/// **已知限制（R3 review A2 定案；R4 review B2 補上可行解）**：`SignInWithAppleButton` 包的
/// `ASAuthorizationAppleIDButton` 標題字級由系統依按鈕高度等比推導，本身**不吃 Dynamic
/// Type**（AX3 實測，iPhone 17 Pro 模擬器 iOS 26：`.frame(minHeight: 56)` 時鈕高固定在
/// 56pt，與一般字級完全相同）——但可以用 `@ScaledMetric` 把基準高度 56pt 綁到 `.body`
/// 文字樣式再灌進 `.frame(height:)`，讓官方鈕的高度（連帶字級，因為字級是依高度等比推導）
/// 跟著 Dynamic Type 撐高，不必換皮／自繪、仍是官方元件，符合 Apple 規範。
///
/// **已知限制（LS-101 R1 review F1 定案）**：上述「跟著 Dynamic Type 撐高」在 AX3 只把官方鈕
/// 標籤放大到約 1.43–1.47×，而 Google／Email 鈕（`.appFont(.lead, weight: .medium)`，見
/// `AuthButtons.swift`）在 AX3 放大約 1.86–1.88×——**官方鈕標題字級對高度不是線性關係，會
/// 提早封頂**，兩者在 AX3 無法對齊。實測（iPhone 17 Pro 模擬器，AX3，逐行 ink 高度）：
/// 一般字級 Apple 20.0pt／Google 21.0pt／Email 19.0pt（一致）；AX3 Apple ≈28.7pt(86px)／
/// Google ≈39.0pt(117px)／Email ≈35.7pt(107px)（Apple 明顯落後 Google／Email，後兩者彼此仍
/// 同步）。R1 review 判斷這不是本 PR 造成的迴歸——換掉 `relativeTo` 或硬做上限只會讓 Google／
/// Email 也跟著變形，不值得為了追平官方元件的先天限制犧牲它們自己的 Dynamic Type 曲線；
/// 因此**這裡刻意不修**，AX3 下 Apple 與 Google／Email 的字級發散是接受的已知限制，不是缺陷。
struct AppleSignInButton: View {
    let isSigningIn: Bool
    let onRequest: (ASAuthorizationAppleIDRequest) -> Void
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat = 56

    var body: some View {
        ZStack {
            SignInWithAppleButton(.signIn, onRequest: onRequest, onCompletion: onCompletion)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: buttonHeight)
                // 圓角對齊 Primary／Secondary／Google 鈕同一個 token（LS-101 point 2）：
                // 官方按鈕預設 cornerRadius 是 6pt，不套 token 會與其他三顆鈕（14pt）不齊。
                .cornerRadius(AppSpacing.radiusMedium)
                .disabled(isSigningIn)
                .opacity(isSigningIn ? 0 : 1)
                .accessibilityHidden(isSigningIn)

            if isSigningIn {
                HStack(spacing: AppSpacing.label) {
                    ProgressView().tint(Color.lsAppleForeground)
                    Text("登入中…").appFont(.body).foregroundStyle(Color.lsAppleForeground)
                }
                .frame(maxWidth: .infinity)
                // 疊層要跟官方鈕「同尺寸」蓋住它（見上方檔案註解）：minHeight 改用同一個
                // buttonHeight，而不是留著舊的硬寫 56，否則官方鈕撐高之後疊層會對不上。
                .frame(minHeight: buttonHeight)
                .background(Color.lsAppleBackground, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在使用 Apple 登入")
            }
        }
    }
}
