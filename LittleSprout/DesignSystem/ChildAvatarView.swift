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
///
/// **LS-293：載入失敗（`.failure` phase）延遲重試一次**（源自 LS-273 merge-review R1
/// `498c8e5a` i1：任何暫時性網路失敗或下載 task 被取消，`AsyncImage` 都不會自己重試，卡在
/// 縮寫直到有別的事觸發重建）。`retryToken` 與 LS-174 那次被推翻的 `.id(avatarURL)` 嘗試**不
/// 是同一種東西**：`avatarURL` 在一次上傳裡會連續變兩次（過渡態→最終值，見
/// `ChildrenStoreAvatarListRefreshTests` 檔頭），`.id(avatarURL)` 因此會被那兩次連續重建互相
/// 取消；`retryToken` 只在 `.failure` 觸發、且刻意延遲 0.5 秒之後才前進一格，跟 `avatarURL`
/// 上游狀態是否原子寫入無關，也只翻一次（見 `ChildAvatarRetryState`）。
struct ChildAvatarView: View {
    let name: String
    var size: CGFloat = 48
    /// 「已移除的寶貝」列（09 揭露列、10b 下拉選單）用灰化樣式，區別於在案的寶貝。
    var isDimmed = false
    /// 短效簽名 URL（`ChildrenStore.avatarURL(for:)`）；nil 時退回縮寫——呼叫端不需要自己
    /// 判斷「這個孩子有沒有頭像」，缺圖與簽名還沒回來是同一種畫面（顯示縮寫）。
    var avatarURL: URL?

    /// LS-293：`.failure` phase 該不該觸發重試的純狀態機（只重試一次）。
    @State private var retryState = ChildAvatarRetryState()
    /// 只在確定要重試時才前進一格，逼 `AsyncImage` 用新身分重建、觸發一次新的下載 task——
    /// 不改變 `avatarURL` 本身，語意上等同 cache-busting。
    @State private var retryToken = 0

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
                    } else if case .failure = phase {
                        // LS-293：`.task(id: retryToken)` 綁在目前這一輪 token 上——
                        // `retryToken` 真的前進之後，新一輪的 task 會發現
                        // `retryState.shouldRetry()` 已經是 false 而立刻返回，不會無限重試。
                        initialsText
                            .task(id: retryToken) { await scheduleRetryIfNeeded() }
                    } else {
                        initialsText
                    }
                }
                .id(retryToken)
                .frame(width: size, height: size)
                .clipShape(Circle())
            }
            .accessibilityHidden(true)
    }

    /// 只在還沒重試過時排程：延遲 0.5 秒（讓暫時性失敗有機會自行恢復，也避開緊接著的
    /// transition 重建）後把 `retryToken` 前進一格。第二次失敗（`retryState.shouldRetry()`
    /// 已回 false）直接返回，維持顯示縮寫。
    private func scheduleRetryIfNeeded() async {
        guard retryState.shouldRetry() else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        retryToken += 1
    }

    private var initialsText: some View {
        Text(ChildAvatarInitial.initial(for: name))
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(isDimmed ? Color.lsTextSecondary : Color.lsTextPrimary)
    }
}

/// LS-293：`ChildAvatarView` 的 `AsyncImage` 載入失敗時「該不該再試一次」的純狀態機，抽出來
/// 讓行為測試可以直接餵一段可注入的 phase 決策序列驗證，不必真的架設網路 stub 去驅動
/// `AsyncImage` 內部的下載 task（同 `ChildAvatarViewStructureTests` 檔頭的理由：這類時序在
/// `UIHostingController` 裡單獨渲染重現不出來）。
struct ChildAvatarRetryState: Equatable {
    private(set) var hasRetried = false

    /// 回傳 true 代表「這次該觸發重試」；只有第一次呼叫會回 true，之後恆回 false——第二次
    /// 失敗要直接顯示縮寫，不能無限重試。
    mutating func shouldRetry() -> Bool {
        guard !hasRetried else { return false }
        hasRetried = true
        return true
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
