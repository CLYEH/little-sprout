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
                isError: isOTPFieldError,
                isLocked: model.isLocked
            )
            .sensoryFeedback(.error, trigger: model.lockedInputFeedbackTick)
            if let message = otpMessage {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .appIconFrame(.small)
                        .foregroundStyle(Color.lsDanger)
                        .symbolEffect(.bounce, value: model.lockedInputFeedbackTick)
                    Text(message)
                        .appFont(.note)
                        .foregroundStyle(Color.lsDanger)
                }
            }
        }
    }

    // R2（LS-92 review R1）F1：`lockMessage`（次數用盡）與 `verifyRateLimitMessage`
    // （verify() 自己的 429）是兩個獨立、互不清除的狀態，這裡依優先序合併成單一顯示字串——
    // 兩者實務上互斥（`isLocked` 一旦成立，`verify()` 會在打後端前就 guard 掉，不可能再撞到
    // rate limit），但合併邏輯本身不依賴這個互斥假設，各自獨立也不會顯示錯內容。
    private var otpMessage: String? {
        model.lockMessage ?? verifyRateLimitMessage ?? model.errorMessage
    }

    private var verifyRateLimitMessage: String? {
        guard let seconds = model.verifyRateLimitSecondsRemaining else { return nil }
        // R2 F3：秒數為 0 代表「有訊息、但解不出真實秒數」——不承諾等待時間。
        return seconds > 0
            ? "太多次嘗試了，請等 \(seconds) 秒再試。"
            : "太多次嘗試了，請稍候一下再試一次。"
    }

    private var isOTPFieldError: Bool {
        model.lockMessage != nil || model.verifyRateLimitSecondsRemaining != nil || model.errorMessage != nil
    }

    private var footerNoteText: String {
        otpMessage == nil
            ? "驗證碼 10 分鐘內有效。找不到信時，請看一下垃圾郵件匣。"
            : "驗證碼 10 分鐘內有效。沒看到信？看一下垃圾郵件匣。"
    }

    @ViewBuilder
    private var resendRow: some View {
        // LS-17 QA1 R2 F1：padding 移進 Button label（原本掛在外層 Group／Button 外面，
        // SwiftUI 的 padding 不參與 hit test，可點區量不到——merge-reviewer R1 blocker F1）；
        // `.contentShape(Rectangle())` 接在 `.padding()` 之後（I1）。倒數態 HStack 自留同一行
        // padding，一般字級下兩態高度仍一致；I2：這個「等高」只在一般字級成立，AX 字級下倒數
        // 態文案較長會多換一行、比可按態高，屬既有行為、非本次引入，不強求逐 px 相等。
        if model.canResend {
            Button(action: resend) {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "arrow.clockwise").appIconFrame(.medium)
                    Text("重新寄一次驗證碼").appFont(.body)
                }
                .padding(.vertical, AppSpacing.group)
                .contentShape(Rectangle())
            }
            .foregroundStyle(Color.lsTextPrimary)
            .disabled(model.isResending || model.isVerifying)
        } else {
            // 四個各自獨立的 Text 在 AX3 下會各自換行，逐行讀出來變成打散的欄位（R3 review
            // B4：「沒收到｜　｜秒後可」三欄式亂序）。併成單一 Text 讓它像一般段落那樣整段
            // 換行，數字段用 monospacedDigit 避免倒數時寬度跳動。I-3／R2（LS-92）：resend()
            // 自己的 429 沿用同一列版面，只在 `model.isResendRateLimited` 時換一句文案，
            // 有真實秒數（`resendRateLimitSecondsAreReal`）才顯示數字並倒數（R2 F3），
            // 不另畫新版面。
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "clock")
                    .appIconFrame(.medium)
                    .foregroundStyle(Color.lsTextSecondary)
                Text(cooldownText)
                    .appFont(.body)
                    .monospacedDigit()
                    .foregroundStyle(Color.lsTextSecondary)
            }
            .padding(.vertical, AppSpacing.group)
            .accessibilityElement(children: .combine)
        }
    }

    private var cooldownText: String {
        guard model.isResendRateLimited else {
            return "沒收到驗證碼？\(model.resendCooldown) 秒後可重新寄送"
        }
        return model.resendRateLimitSecondsAreReal
            ? "寄太頻繁了，請等 \(model.resendCooldown) 秒再試"
            : "寄送太頻繁了，請稍後再試"
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
