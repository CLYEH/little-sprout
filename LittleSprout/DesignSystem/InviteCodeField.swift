import SwiftUI

/// 邀請碼 6 格輸入（06／06b／06c，`design/littlesprout.pen` frame `VCMrA`）：與 `OTPCodeField`
/// 同一個「隱形原生 TextField 承接輸入、六個可視方塊只負責顯示」機制（見該檔文件註解），差異在
/// 這裡收字母＋數字（邀請碼字元集，LS-90）而不是純數字，且畫面上分兩組 3+3 顯示（`groupedCells`
/// 依 `cellCount / 2` 切成兩半，供呼叫端各自包一層 `HStack`）。
///
/// 大寫／去空白由這裡統一處理（票文「大寫去空白」）：`onChange` 把輸入正規化成大寫英數字元，
/// 呼叫端（`JoinCodeView`）不需要自己再處理格式。
struct InviteCodeField: View {
    @Binding var code: String
    var isError: Bool
    var cellCount: Int = 6

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: AppSpacing.block) {
                groupView(cellRange: 0..<(cellCount / 2))
                groupView(cellRange: (cellCount / 2)..<cellCount)
            }
            TextField("", text: $code)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityHidden(true)
                .onChange(of: code) { _, newValue in
                    code = Self.normalize(newValue, cellCount: cellCount)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("邀請碼輸入，共 \(cellCount) 位英數字")
        .accessibilityValue(code.isEmpty ? "尚未輸入" : code.map(String.init).joined(separator: " "))
    }

    /// 去除非英數字元、轉大寫、截到 `cellCount` 位——`request_join` RPC 本來就會做同一套
    /// 正規化（見 docs/API.md §7「碼比對已內建正規化」），這裡提前做只是為了畫面顯示乾淨，
    /// 不是安全邊界。
    static func normalize(_ raw: String, cellCount: Int = 6) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(cellCount))
    }

    private func groupView(cellRange: Range<Int>) -> some View {
        HStack(spacing: AppSpacing.label) {
            ForEach(cellRange, id: \.self) { index in
                cell(at: index)
            }
        }
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
    VStack(spacing: AppSpacing.block) {
        InviteCodeField(code: .constant("K7M2F"), isError: false)
        InviteCodeField(code: .constant("K7M2F8"), isError: true)
    }
    .padding()
}
