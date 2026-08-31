import SwiftUI

/// 姓名縮寫圓圈——`cmp/Child Avatar`（`design/littlesprout.pen` `RaaIf`）。LS-67 設計註記
/// E3：本稿頭像一律用姓名縮寫圓圈（無真人照片），大頭貼上傳／裁切另開任務；這裡先只做
/// 縮寫圓，`avatarURL` 目前恆為 nil（見 `CreateChildView`／`EditChildView` 文件註解）。
///
/// 圓圈尺寸與縮寫文字刻意都不吃 Dynamic Type：縮寫是裝飾性的識別符號（跟角托同類、見
/// `PhotoCornerShape` 文件），旁邊一定伴隨會隨 Dynamic Type 放大的姓名文字，縮寫本身放大
/// 只會讓固定尺寸的圓圈溢出，不會增加可讀性。
struct ChildAvatarView: View {
    let name: String
    var size: CGFloat = 48
    /// 「已移除的寶貝」列（09 揭露列、10b 下拉選單）用灰化樣式，區別於在案的寶貝。
    var isDimmed = false

    var body: some View {
        Circle()
            .fill(isDimmed ? Color.lsSurface2 : Color.lsAccentSoft)
            .frame(width: size, height: size)
            .overlay(
                Text(ChildAvatarInitial.initial(for: name))
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(isDimmed ? Color.lsTextSecondary : Color.lsTextPrimary)
            )
            .accessibilityHidden(true)
    }
}

/// 縮寫抽取：中文姓名取「最後一個字」（陳小安→安，符合稿面示例）；非 CJK（例如
/// 「Emma Chen」）取首字母大寫，兩種取法都只看字面、不做語言偵測。
enum ChildAvatarInitial {
    static func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        if last.isASCII, let first = trimmed.first {
            return String(first).uppercased()
        }
        return String(last)
    }
}

#Preview {
    HStack(spacing: 16) {
        ChildAvatarView(name: "陳小安")
        ChildAvatarView(name: "陳小軒", size: 28)
        ChildAvatarView(name: "Emma Chen", isDimmed: true)
    }
    .padding()
}
