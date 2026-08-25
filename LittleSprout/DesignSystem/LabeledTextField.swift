import SwiftUI

/// `cmp/Text Field`：標題 + 輸入框 + 說明列。錯誤態走通用「錯誤態文法」①②層——邊框轉
/// `$danger` 2pt、說明列換成 icon＋紅字，不加底色塊（Handoff Notes 通用節）。
struct LabeledTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var helpText: String
    var isError = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(label)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)

            TextField(placeholder, text: $text)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .onSubmit { onSubmit?() }
                .padding(.horizontal, AppSpacing.insetCard)
                .padding(.vertical, AppSpacing.controlPaddingMedium)
                .frame(minHeight: 60)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .strokeBorder(isError ? Color.lsDanger : Color.lsControlLine, lineWidth: isError ? 2 : 1.5)
                )

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
    }
    .padding()
}
