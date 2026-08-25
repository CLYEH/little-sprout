import SwiftUI

/// LS-17 / 02 Email 登入 · 輸入信箱（含 02b 格式錯誤）。
///
/// 設計稿的「Email Print」裝飾卡（相片沖印品母題延伸到 Email 畫面，顯示信箱網域）純屬視覺
/// 裝飾、與登入功能無關，本票聚焦「Email OTP 完整流程可用」這條驗收條件，先不做——
/// 詳見 handoff 未完成欄。
struct EmailSignInView: View {
    let authStore: AuthStore
    let onCodeSent: (String) -> Void

    @State private var model: EmailSignInModel

    init(authStore: AuthStore, onCodeSent: @escaping (String) -> Void) {
        self.authStore = authStore
        self.onCodeSent = onCodeSent
        _model = State(initialValue: EmailSignInModel(authStore: authStore))
    }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    VStack(alignment: .leading, spacing: AppSpacing.label) {
                        Text("用 Email 登入")
                            .appFont(.display, weight: .bold)
                            .foregroundStyle(Color.lsTextPrimary)
                        Text("我們會寄一組 6 位數字的驗證碼到你的信箱，不用記密碼。")
                            .appFont(.body)
                            .foregroundStyle(Color.lsTextSecondary)
                    }

                    LabeledTextField(
                        label: "Email 地址",
                        placeholder: "yourname@example.com",
                        text: Binding(get: { model.email }, set: { model.updateEmail($0) }),
                        helpText: model.errorMessage ?? "驗證碼會寄到這個信箱，10 分鐘內有效。",
                        isError: model.errorMessage != nil,
                        keyboardType: .emailAddress,
                        textContentType: .emailAddress,
                        submitLabel: .send,
                        onSubmit: send
                    )

                    Text("沒有 Apple 帳號，或不方便用 Apple 登入時，用 Email 一樣可以登入。")
                        .appFont(.meta)
                        .foregroundStyle(Color.lsTextSecondary)
                }

                Spacer(minLength: AppSpacing.block)

                PrimaryButton(icon: "paperplane.fill", title: "寄送驗證碼", isLoading: model.isSending, action: send)
                    .padding(.bottom, AppSpacing.item)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.label)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() {
        Task {
            if await model.sendCode() {
                onCodeSent(model.email)
            }
        }
    }
}

#Preview {
    NavigationStack {
        EmailSignInView(authStore: .preview()) { _ in }
    }
}
