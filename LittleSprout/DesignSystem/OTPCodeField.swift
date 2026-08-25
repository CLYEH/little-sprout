import SwiftUI

/// `cmp/OTP Cell` × 6：六格獨佔式驗證碼輸入（03／03b）。用一個隱形的原生 `TextField` 承接
/// 鍵盤輸入（含 `.textContentType(.oneTimeCode)` 的簡訊自動填碼建議列），六個可視方塊只負責
/// 顯示——不是六個各自可點的欄位，符合「單一 tap target」規則（見 LS-46 handoff 邀請碼字母集
/// 段：整列是一個輸入框，不是 N 個獨立小按鈕）。
struct OTPCodeField: View {
    @Binding var code: String
    var isError: Bool
    var cellCount: Int = 6
    /// 次數用盡（R2，LS-92 PR #155 review R1 F5）：鎖定當下自動收鍵盤——沒有理由繼續叫出
    /// 數字鍵盤打新號碼。不影響之後再點一次欄位重新叫出鍵盤（刪字／清空仍然放行，見
    /// `OTPVerificationModel.updateCode`），只是不再自動彈出。
    var isLocked: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: AppSpacing.tight) {
                ForEach(0..<cellCount, id: \.self) { index in
                    cell(at: index)
                }
            }
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityHidden(true)
                .onChange(of: code) { _, newValue in
                    code = String(newValue.filter(\.isNumber).prefix(cellCount))
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onChange(of: isLocked) { _, locked in
            if locked { isFocused = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("驗證碼輸入，共 \(cellCount) 位數字")
        .accessibilityValue(code.isEmpty ? "尚未輸入" : code.map(String.init).joined(separator: " "))
    }

    private func cell(at index: Int) -> some View {
        let isCurrent = index == code.count && isFocused
        return Text(character(at: index))
            .appNumericFont(.otp)
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .frame(minHeight: 72)
            .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(borderColor(isCurrent: isCurrent), lineWidth: borderWidth(isCurrent: isCurrent))
            )
    }

    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        let charIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[charIndex])
    }

    private func borderColor(isCurrent: Bool) -> Color {
        if isError { return .lsDanger }
        return isCurrent ? .lsAccent : .lsBorder
    }

    private func borderWidth(isCurrent: Bool) -> CGFloat {
        if isError { return 2 }
        return isCurrent ? 2.5 : 1.5
    }
}

#Preview {
    OTPCodeField(code: .constant("528"), isError: false)
        .padding()
}
