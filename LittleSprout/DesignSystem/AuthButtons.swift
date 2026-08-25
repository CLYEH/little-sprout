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
struct SecondaryButton: View {
    let icon: String
    let title: String
    var isDimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: icon).appIconFrame(.medium)
                Text(title).appFont(.body)
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
/// Google 的四色「G」標是受商標保護的圖形，本票 Google 登入為 stub（無 GoogleSignIn SDK、
/// 未接真實流程——見環境規約），因此這裡用中性 SF Symbol 佔位，不手繪 G 標；接上真的
/// Google 登入時應改用 GoogleSignIn SDK 提供的官方按鈕／G 標資產（Handoff Notes「三方登入鍵
/// 的色彩豁免」）。
struct GoogleSignInButton: View {
    var isDimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.group) {
                Image(systemName: "g.circle.fill").appIconFrame(.google)
                Text("使用 Google 登入").appFont(.body)
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

#Preview {
    VStack(spacing: AppSpacing.label) {
        PrimaryButton(icon: "paperplane", title: "寄送驗證碼", action: {})
        PrimaryButton(icon: "paperplane", title: "寄送驗證碼", isLoading: true, action: {})
        SecondaryButton(icon: "envelope", title: "使用 Email 登入", action: {})
        SecondaryButton(icon: "envelope", title: "使用 Email 登入", isDimmed: true, action: {})
        GoogleSignInButton(action: {})
    }
    .padding()
}
