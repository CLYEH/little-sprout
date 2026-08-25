import SwiftUI

/// `cmp/Button Primary`：實心 accent，全 app「一畫面一 accent」的唯一主要動作。
struct PrimaryButton: View {
    let icon: String
    let title: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                if isLoading {
                    ProgressView().tint(Color.lsOnAccent)
                } else {
                    Image(systemName: icon).appIconFrame(.medium)
                }
                Text(isLoading ? "正在處理…" : title).appFont(.body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingCTA)
            .padding(.horizontal, 20)
        }
        .foregroundStyle(Color.lsOnAccent)
        .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .disabled(isLoading)
    }
}

/// `cmp/Button Secondary`：無填色、`$control-line` 外框——次要動作樣式，不是停用樣式
/// （Handoff Notes 通用節「全稿『看起來不能用』掃描」）。`isDimmed` 對應 01b 登入中時
/// Google／Email 鍵轉 `$surface-2` 的暫時態，不是永久的 disabled 視覺語彙。
///
/// 字級／字重見 LS-101 point 5：官方 `SignInWithAppleButton` 不開放自訂字型（見
/// `AppleSignInButton.swift` R3/R4 review 定論），因此文字改對齊 Apple 鈕實測值，而不是反過來。
/// 這裡只在 WelcomeView 用（見用量檢查），不影響其他畫面。
struct SecondaryButton: View {
    let icon: String
    let title: String
    var isDimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: icon).appIconFrame(.medium)
                Text(title).appFont(.lead, weight: .medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, 20)
        }
        .foregroundStyle(Color.lsTextPrimary)
        .background(
            isDimmed ? Color.lsSurface2 : Color.clear,
            in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
        )
        .disabled(isDimmed)
    }
}

/// `cmp/Button Google`：品牌硬規定的官方樣式（底色／外框／字色三個 token 不得改）。
///
/// Google 的四色「G」標是受商標保護的圖形（LS-101 point 3）：`GoogleG` 資產直接取自 Google
/// 官方 CDN（`fonts.gstatic.com/s/i/productlogos/googleg/v6/24px.svg`，Google Sign-In branding
/// guidelines 指定資產），非手繪重製，`template-rendering-intent: original` 防止被當 template
/// 圖示套色。LS-39 定案：Google 登入走 Supabase OAuth＋`ASWebAuthenticationSession`（不裝
/// GoogleSignIn SDK、不建 iOS 類型 OAuth client），這顆自畫鈕即為正式實作，不再是 stub
/// （Handoff Notes「三方登入鍵的色彩豁免」允許自畫、不強制用 SDK 官方按鈕）。
struct GoogleSignInButton: View {
    var isDimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.group) {
                Image("GoogleG").resizable().scaledToFit().appIconFrame(.google)
                Text("使用 Google 登入").appFont(.lead, weight: .medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, 20)
        }
        .foregroundStyle(Color.lsGoogleForeground)
        .background(
            isDimmed ? Color.lsSurface2 : Color.lsGoogleBackground,
            in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(Color.lsGoogleLine, lineWidth: 1)
        )
        .disabled(isDimmed)
    }
}

// R1 review F3：`PrimaryButton`（`.body` 17pt，EmailSignInView／OTPVerificationView 用）與
// `SecondaryButton`／`GoogleSignInButton`（`.lead` 22pt medium，只有 WelcomeView 用，LS-101
// point 5 對齊 Apple 官方鈕實測值）字級不同——分成兩個 Preview，各自反映實際出現的畫面情境，
// 不要把兩種字級併在同一張預覽裡看起來像沒對齊。

#Preview("Primary（EmailSignInView／OTPVerificationView）") {
    VStack(spacing: AppSpacing.label) {
        PrimaryButton(icon: "paperplane", title: "寄送驗證碼", action: {})
        PrimaryButton(icon: "paperplane", title: "寄送驗證碼", isLoading: true, action: {})
    }
    .padding()
}

#Preview("Secondary／Google（WelcomeView）") {
    VStack(spacing: AppSpacing.group) {
        SecondaryButton(icon: "envelope", title: "使用 Email 登入", action: {})
        SecondaryButton(icon: "envelope", title: "使用 Email 登入", isDimmed: true, action: {})
        GoogleSignInButton(action: {})
    }
    .padding()
}
