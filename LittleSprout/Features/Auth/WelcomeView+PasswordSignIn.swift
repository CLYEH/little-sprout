import SwiftUI

// LS-164：獨立檔案（不是塞進 WelcomeView.swift 本體）——那個檔案加上這段就會超過 SwiftLint
// file_length 上限，同 `CreateChildView+Avatar.swift` 的既有拆檔理由。`path`／`authButtonsState`
// 因此改成非 private（見 WelcomeView.swift 該兩處註解），讓這裡的 extension 能存取。
extension WelcomeView {
    /// 審核帳號用的帳密登入入口——小字文字鈕，不做成第四顆大按鈕、不用 `$accent`，不跟
    /// Apple／Google／Email 三顆主要動作搶注意力（LS-163 核可頁裁決：連結色用 `$text-primary`
    /// ＋1pt 底線，不是票文原稿的 `$text-secondary`——品牌十條「文字連結必須看得出可以點」
    /// 勝出）。`.frame(maxWidth: .infinity)` 讓熱區橫跨整列並置中文字，`.padding(.vertical,
    /// AppSpacing.group)` 撐滿熱區（同 `OTPVerificationView.resendRow` 既有作法）。
    ///
    /// merge-review R1 N2：只疊 `AppSpacing.group` padding 實測 354.0×44.33pt——比 44pt 硬約束
    /// 只多 0.33pt 餘裕，跟 `LabeledTextField.swift` 密碼欄「顯示」切換鈕（同一份 review）撞過
    /// 同一種事故（`.frame(minHeight: 44)` 實測量到 43.9x 被判 FAIL）同型：字型行高只要日後被
    /// 系統／語系調整 0.34pt 以上就會掉到 44pt 以下。比照那裡補 `.frame(minHeight: 46)` 拉開
    /// 保險係數，不能只靠 padding 疊出來的高度。
    ///
    /// N8：`.opacity` 讓連結在 in-flight（Apple／Google 登入中）時跟 Google／Email 兩顆鈕一樣
    /// 有視覺變化——原本只有 `.disabled()`，看起來仍像可點。
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
                .frame(minHeight: 46)
                .contentShape(Rectangle())
        }
        .disabled(authButtonsState.emailIsDimmed)
        .opacity(authButtonsState.emailIsDimmed ? 0.5 : 1)
    }
}
