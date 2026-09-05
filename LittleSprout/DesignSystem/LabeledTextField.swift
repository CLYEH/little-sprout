import SwiftUI

/// `cmp/Text Field`：標題 + 輸入框 + 說明列。錯誤態走通用「錯誤態文法」①②層——邊框轉
/// `$danger` 2pt、說明列換成 icon＋紅字，不加底色塊（Handoff Notes 通用節）。
struct LabeledTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    /// LS-164：改為可選——`PasswordSignInView` 的 Email／密碼兩欄共用同一段錯誤說明文字
    /// （只出現在密碼欄下方，見 LS-163 核可頁 P1c 板），Email 欄在錯誤態下只需要紅框、不需要
    /// 再重複一次自己的 help row。nil＝不渲染這一列（不是渲染一列空字串留白）。
    var helpText: String?
    var isError = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)?
    /// LS-164：密碼欄用——`true` 時預設用 `SecureField` 遮蔽輸入，並在欄位內顯示「顯示／隱藏」
    /// 切換鈕（LS-163 核可頁 P1 板，眼睛 icon＋文字）。切換狀態是這個 View 自己的呈現細節，
    /// 不需要外部 model 知道，因此用內部 `@State` 而不是額外的 binding。
    var isSecure = false
    /// LS-158：QA e2e（`LittleSproutUITests/QA`）找輸入框用的 identifier（值見 `QAAccessibilityID`）；
    /// 掛在裡面的 `TextField` 本體，不掛外層 `VStack`（容器不是 accessibility element）。nil＝不掛。
    var accessibilityIdentifier: String?

    @State private var isPasswordRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(label)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)

            fieldRow

            if let helpText {
                HStack(alignment: .top, spacing: AppSpacing.label) {
                    if isError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .appIconFrame(.small)
                            .foregroundStyle(Color.lsDanger)
                    }
                    Text(helpText)
                        .appFont(.note)
                        .fontWeight(isError ? .semibold : .regular)
                        .foregroundStyle(isError ? Color.lsDanger : Color.lsTextSecondary)
                        // AX3 下父層版面提案的高度可能比這段文字的完整換行高度小；沒有這個
                        // modifier，Text 會依提案高度截斷成一行加「…」（R3 review A1，02b 錯誤
                        // 訊息在 AX3 只剩半句、底下卻留 100pt+ 空白）。加了之後 Text 永遠回報
                        // 完整換行所需的高度，把父層 VStack 撐開。
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var fieldRow: some View {
        HStack(spacing: AppSpacing.label) {
            Group {
                if isSecure && !isPasswordRevealed {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .accessibilityIdentifier(accessibilityIdentifier ?? "")

            if isSecure {
                Button {
                    isPasswordRevealed.toggle()
                } label: {
                    HStack(spacing: AppSpacing.tight) {
                        Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                            .appIconFrame(.small)
                        Text(isPasswordRevealed ? "隱藏" : "顯示")
                            .appFont(.note, weight: .semibold)
                    }
                    // 點擊目標 gate 實測：文字＋icon 本身只有 ~20pt 高，遠低於長輩硬約束
                    // ≥44pt——`minHeight` 撐開熱區，`.contentShape(Rectangle())` 讓撐開的範圍
                    // 真的參與 hit test（同 `OTPVerificationView.resendRow` 既有作法），欄位本身
                    // `minHeight: 60` 留得下這 46pt。46（不是剛好 44）：實測模擬器量到的
                    // accessibility frame 比 SwiftUI layout 值略小一點點（次像素捨入），卡在
                    // 44.0pt 邊界會被 `< 44` 判成違規（實測撞到：`.frame(minHeight: 44)` 量出
                    // 43.9x pt，格式化四捨五入顯示成「44.0pt」但仍判定 FAIL）。
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(Color.lsTextPrimary)
                .accessibilityLabel(isPasswordRevealed ? "隱藏密碼" : "顯示密碼")
            }
        }
        .appFont(.body)
        .foregroundStyle(Color.lsTextPrimary)
        .padding(.horizontal, AppSpacing.insetCard)
        .padding(.vertical, AppSpacing.controlPaddingMedium)
        .frame(minHeight: 60)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(isError ? Color.lsDanger : Color.lsControlLine, lineWidth: isError ? 2 : 1.5)
        )
    }
}

#Preview {
    VStack(spacing: AppSpacing.block) {
        LabeledTextField(
            label: "Email 地址",
            placeholder: "yourname@example.com",
            text: .constant(""),
            helpText: "驗證碼會寄到這個信箱，10 分鐘內有效。"
        )
        LabeledTextField(
            label: "Email 地址",
            placeholder: "yourname@example.com",
            text: .constant("grandma@example"),
            helpText: "這個 Email 好像沒打完，請再看一次，格式像 name@example.com",
            isError: true
        )
        // LS-164：密碼欄——一般態（helpText nil，不渲染 help row）與紅框態（Email／密碼共用
        // 同一段錯誤說明，實際文案掛在 PasswordSignInView，這裡只示範紅框視覺）。
        LabeledTextField(
            label: "密碼",
            placeholder: "請輸入密碼",
            text: .constant(""),
            isSecure: true
        )
        LabeledTextField(
            label: "密碼",
            placeholder: "請輸入密碼",
            text: .constant("wrong-password"),
            isError: true,
            isSecure: true
        )
    }
    .padding()
}
