import SwiftUI

/// 頭像圓圈——`cmp/Child Avatar`（`design/littlesprout.pen` `RaaIf`）。LS-67 設計註記 E3：
/// 有 `avatarURL` 時顯示照片，沒有時退回姓名縮寫圓圈（LS-169 落地「大頭貼上傳／裁切另開
/// 任務」——這裡就是那個任務）。
///
/// 圓圈尺寸與縮寫文字刻意都不吃 Dynamic Type：縮寫是裝飾性的識別符號（跟角托同類，見
/// `PhotoCornerShape` 文件），旁邊一定伴隨會隨 Dynamic Type 放大的姓名文字，縮寫本身放大
/// 只會讓固定尺寸的圓圈溢出，不會增加可讀性——照片同理，不隨字級縮放。
///
/// **LS-273：`AsyncImage` 恆存在，不得再包回 `if let avatarURL` 條件式**。原本的寫法是
/// 「有 URL 就放一個 `AsyncImage`，沒有就放縮寫文字」——`avatarURL` 由 nil 變成非 nil 時
/// SwiftUI 會**新建**一個 `AsyncImage`，而「第一次幫寶貝設定頭像」這條路徑上，這次新建
/// 恰好落在「儲存成功 → `dismiss()` → 導覽 pop 動畫」的同一瞬間：新建的 `AsyncImage`
/// 內部下載 task 在真的送出 GET 之前就被 transition 的重建取消，`AsyncImage` 又不會自己
/// 重試（`url` 沒變＝它認為沒事可做），於是那一列停在 `.empty`（畫縮寫）直到有別的事
/// 讓它重建為止。本機實測（LS-273，證據
/// `.claude/evidence/LS-273/qa-e2e/browse-20260914-213840/`）：存檔返回列表後那一列連續
/// 30 秒不換圖，期間 Storage log **完全沒有任何 GET**；同一支流程「換掉既有頭像」卻是
/// 0.1 秒就換圖——差別只在那時 `AsyncImage` 已經存在、只是 `url` 換了值。把它提到條件式
/// 外面之後，兩條路徑走的是同一件事（同一個實例換 `url`），三輪實跑皆 0.1 秒刷新
/// （`.claude/evidence/LS-273/qa-e2e/browse-20260914-214742/`）。
/// 結構不變量由 `ChildAvatarViewStructureTests` 釘住；**想在這裡加 `.id()` 之前**請先讀
/// `ChildrenStoreAvatarListRefreshTests` 檔頭（LS-174 實測：`.id()` 會放大這個 race）。
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
            // LS-273：`AsyncImage` 刻意**不包在 `if let avatarURL` 裡**——`url` 參數本身吃
            // `URL?`，nil 時它就停在 `.empty` phase、由下面的 closure 畫縮寫，畫面結果與
            // 原本的條件式寫法逐位相同，但 view 的**身分**不再隨「有沒有簽名 URL」改變。
            // 見型別本身的文件註解。
            .overlay {
                AsyncImage(url: avatarURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        initialsText
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
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
