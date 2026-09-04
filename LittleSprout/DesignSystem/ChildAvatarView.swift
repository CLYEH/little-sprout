import SwiftUI

/// 頭像圓圈——`cmp/Child Avatar`（`design/littlesprout.pen` `RaaIf`）。LS-67 設計註記 E3：
/// 有 `avatarURL` 時顯示照片，沒有時退回姓名縮寫圓圈（LS-169 落地「大頭貼上傳／裁切另開
/// 任務」——這裡就是那個任務）。
///
/// 圓圈尺寸與縮寫文字刻意都不吃 Dynamic Type：縮寫是裝飾性的識別符號（跟角托同類，見
/// `PhotoCornerShape` 文件），旁邊一定伴隨會隨 Dynamic Type 放大的姓名文字，縮寫本身放大
/// 只會讓固定尺寸的圓圈溢出，不會增加可讀性——照片同理，不隨字級縮放。
struct ChildAvatarView: View {
    let name: String
    var size: CGFloat = 48
    /// 「已移除的寶貝」列（09 揭露列、10b 下拉選單）用灰化樣式，區別於在案的寶貝。
    var isDimmed = false
    /// 短效簽名 URL（`ChildrenStore.avatarURL(for:)`）；nil 時退回縮寫——呼叫端不需要自己
    /// 判斷「這個孩子有沒有頭像」，缺圖與簽名還沒回來是同一種畫面（顯示縮寫）。
    var avatarURL: URL?

    var body: some View {
        Circle()
            .fill(isDimmed ? Color.lsSurface2 : Color.lsAccentSoft)
            .frame(width: size, height: size)
            .overlay {
                if let avatarURL {
                    AsyncImage(url: avatarURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            initialsText
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                } else {
                    initialsText
                }
            }
            .accessibilityHidden(true)
    }

    private var initialsText: some View {
        Text(ChildAvatarInitial.initial(for: name))
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(isDimmed ? Color.lsTextSecondary : Color.lsTextPrimary)
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
