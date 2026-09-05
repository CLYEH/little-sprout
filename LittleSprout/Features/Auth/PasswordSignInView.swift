import SwiftUI

/// LS-164 / P1 帳號密碼登入（審核帳號用，方案 B；含 P1b 登入中／P1c 帳號或密碼錯誤／P1d 網路
/// 錯誤）。設計稿見 LS-163 核可頁：板 `P1 帳號密碼登入` 系列（`design/littlesprout.pen`，
/// 節點 `BYbe5`／`pl5GE`／`O1XC2Z`／`ioA0u`／`tpw7n`）。
///
/// AX3：核可頁該板本身有跑版（Email／密碼欄的多行 placeholder 撐破欄位邊框），由另一張設計
/// chore 修正稿面本身——這裡以設計意圖為準：兩個欄位、登入鈕、求助行在任何字級下都要能各自
/// 撐開高度、不重疊、不裁切，不照抄稿面現況（見 LS-164 票文「0905 核可補充」）。做法是全程
/// 沿用 `EmailSignInView`／`OTPVerificationView` 已經在 AX3 驗證過的版式：`LabeledTextField`
/// 用 `minHeight`（不是固定 `height`）自然撐高、`ScrollableFillView` 讓超出一屏的內容可捲動、
/// CTA 用 `safeAreaInset` 固定在鍵盤上方。
struct PasswordSignInView: View {
    let authStore: AuthStore
    let onSignedIn: () -> Void

    @State private var model: PasswordSignInModel

    init(authStore: AuthStore, onSignedIn: @escaping () -> Void) {
        self.authStore = authStore
        self.onSignedIn = onSignedIn
        _model = State(initialValue: PasswordSignInModel(authStore: authStore))
    }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: AppSpacing.block) {
                header
                fieldsSection
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.label)
        }
        // 理由同 EmailSignInView／OTPVerificationView：ScrollView 已自帶鍵盤 safe-area inset，
        // CTA 固定在鍵盤上方，AX3 長輩字級下不需要捲動就看得到「登入」鈕。
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: AppSpacing.label) {
                // 非帳密錯誤（網路／伺服器…）顯示在這裡，貼著登入鈕上方（LS-163 核可頁 P1d
                // 板）——帳密錯誤走 `passwordField` 自己的 `helpText`（見 fieldsSection），
                // 兩種錯誤版面位置不同，見 `PasswordSignInModel` 文件註解。
                if !model.isCredentialsError, let message = model.errorMessage {
                    nonCredentialsErrorRow(message)
                }
                PrimaryButton(
                    icon: "arrow.right", title: "登入",
                    isLoading: model.isSigningIn, loadingTitle: "登入中…", action: signIn
                )
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, AppSpacing.item)
            // PR #165 review I1：理由同 OTPVerificationView／EmailSignInView。
            .background(Color.lsBackground)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("帳號密碼登入")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("審核專用登入方式，請輸入分配給你的帳號與密碼。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            LabeledTextField(
                label: "Email 地址",
                placeholder: "yourname@example.com",
                text: Binding(get: { model.email }, set: { model.updateEmail($0) }),
                isError: model.isCredentialsError,
                keyboardType: .emailAddress,
                textContentType: .emailAddress,
                accessibilityIdentifier: QAAccessibilityID.passwordSignInEmailField
            )

            // 帳密錯誤時，說明文字掛在密碼欄的 helpText——Email 欄只變紅框、不重複同一句話
            // （見 LS-163 核可頁 P1c 板：兩欄一起變紅，紅字只出現一次，在密碼欄下方）。
            LabeledTextField(
                label: "密碼",
                placeholder: "請輸入密碼",
                text: Binding(get: { model.password }, set: { model.updatePassword($0) }),
                helpText: model.isCredentialsError ? model.errorMessage : nil,
                isError: model.isCredentialsError,
                textContentType: .password,
                submitLabel: .go,
                onSubmit: signIn,
                isSecure: true,
                accessibilityIdentifier: QAAccessibilityID.passwordSignInPasswordField
            )

            infoRow
        }
    }

    /// 求助行——不論有無錯誤都顯示（LS-163 核可頁三個狀態板皆同一行），審核人員登不進去時
    /// 唯一的求助管道不能因為畫面切換而消失。
    private var infoRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "info.circle")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextSecondary)
            Text("此為審核專用帳號，如需協助請洽開發者聯絡資訊。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nonCredentialsErrorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.triangle.fill")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsDanger)
            Text(message)
                .appFont(.note)
                .fontWeight(.semibold)
                .foregroundStyle(Color.lsDanger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signIn() {
        Task {
            if await model.signIn() {
                onSignedIn()
            }
        }
    }
}

#if DEBUG
#Preview("Light") {
    NavigationStack {
        PasswordSignInView(authStore: .preview()) {}
    }
}

#Preview("Dark") {
    NavigationStack {
        PasswordSignInView(authStore: .preview()) {}
    }
    .preferredColorScheme(.dark)
}

#Preview("AX3") {
    NavigationStack {
        PasswordSignInView(authStore: .preview()) {}
    }
    .dynamicTypeSize(.accessibility3)
}
#endif
