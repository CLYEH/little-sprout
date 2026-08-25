import SwiftUI

/// LS-17 / 03 Email 登入 · 輸入驗證碼（含 03b 驗證碼錯誤）。
struct OTPVerificationView: View {
    let email: String
    let authStore: AuthStore
    let onVerified: () -> Void

    @State private var model: OTPVerificationModel

    init(email: String, authStore: AuthStore, onVerified: @escaping () -> Void) {
        self.email = email
        self.authStore = authStore
        self.onVerified = onVerified
        _model = State(initialValue: OTPVerificationModel(email: email, authStore: authStore))
    }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    header
                    otpSection
                    Text(footerNoteText)
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextPrimary)
                }

                Spacer(minLength: AppSpacing.item)

                VStack(spacing: AppSpacing.label) {
                    resendRow
                    PrimaryButton(icon: "arrow.right", title: "確認登入", isLoading: model.isVerifying, action: verify)
                }
                .padding(.bottom, AppSpacing.item)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.label)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task { model.startCooldown() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("輸入驗證碼")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("6 位數字已寄到")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
            Text(email)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)
        }
    }

    private var otpSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            OTPCodeField(
                code: Binding(get: { model.code }, set: { model.updateCode($0) }),
                isError: model.errorMessage != nil
            )
            if let errorMessage = model.errorMessage {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .appIconFrame(.small)
                        .foregroundStyle(Color.lsDanger)
                    Text(errorMessage)
                        .appFont(.note)
                        .foregroundStyle(Color.lsDanger)
                }
            }
        }
    }

    private var footerNoteText: String {
        model.errorMessage == nil
            ? "驗證碼 10 分鐘內有效。找不到信時，請看一下垃圾郵件匣。"
            : "驗證碼 10 分鐘內有效。沒看到信？看一下垃圾郵件匣。"
    }

    @ViewBuilder
    private var resendRow: some View {
        // LS-17 QA1：兩態共用 `.padding(.vertical, AppSpacing.group)`，讓可互動態的點擊區
        // ≥44pt（長輩硬約束）之餘，倒數態高度跟著一起長，避免冷卻結束切到可按態時版面跳動。
        Group {
            if model.canResend {
                Button(action: resend) {
                    HStack(spacing: AppSpacing.tight) {
                        Image(systemName: "arrow.clockwise").appIconFrame(.medium)
                        Text("重新寄一次驗證碼").appFont(.body)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(Color.lsTextPrimary)
                .disabled(model.isResending || model.isVerifying)
            } else {
                // 四個各自獨立的 Text 在 AX3 下會各自換行，逐行讀出來變成打散的欄位（R3 review
                // B4：「沒收到｜　｜秒後可」三欄式亂序）。併成單一 Text 讓它像一般段落那樣整段
                // 換行，數字段用 monospacedDigit 避免倒數時寬度跳動。
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "clock")
                        .appIconFrame(.medium)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text("沒收到驗證碼？\(model.resendCooldown) 秒後可重新寄送")
                        .appFont(.body)
                        .monospacedDigit()
                        .foregroundStyle(Color.lsTextSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, AppSpacing.group)
    }

    private func verify() {
        Task {
            if await model.verify() {
                onVerified()
            }
        }
    }

    private func resend() {
        Task { await model.resend() }
    }
}

#Preview {
    NavigationStack {
        OTPVerificationView(email: "grandma@example.com", authStore: .preview()) {}
    }
}
