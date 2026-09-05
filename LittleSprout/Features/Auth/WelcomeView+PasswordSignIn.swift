import SwiftUI

// LS-164：獨立檔案（不是塞進 WelcomeView.swift 本體）——那個檔案加上這段就會超過 SwiftLint
// file_length 上限，同 `CreateChildView+Avatar.swift` 的既有拆檔理由。`path`／`authButtonsState`
// 因此改成非 private（見 WelcomeView.swift 該兩處註解），讓這裡的 extension 能存取。
extension WelcomeView {
    /// 審核帳號用的帳密登入入口——小字文字鈕，不做成第四顆大按鈕、不用 `$accent`，不跟
    /// Apple／Google／Email 三顆主要動作搶注意力（LS-163 核可頁裁決：連結色用 `$text-primary`
    /// ＋1pt 底線，不是票文原稿的 `$text-secondary`——品牌十條「文字連結必須看得出可以點」
    /// 勝出）。`.frame(maxWidth: .infinity)` 讓熱區橫跨整列並置中文字，`.padding(.vertical,
    /// AppSpacing.group)` 撐滿 ≥44pt 熱區（同 `OTPVerificationView.resendRow` 既有作法）。
    /// 複用 `authButtonsState.emailIsDimmed`：跟 Email 鈕同一組「任一登入方式在跑就暫時不可按」
    /// 的互斥規則，不需要另外的旗標。
    var passwordSignInLink: some View {
        Button {
            path.append(.passwordSignIn)
        } label: {
            Text("以帳號密碼登入")
                .appFont(.note)
                .underline()
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.group)
                .contentShape(Rectangle())
        }
        .disabled(authButtonsState.emailIsDimmed)
    }
}
