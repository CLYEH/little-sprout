import SwiftUI

/// LS-189（依 LS-152 稿 `EXgzz`）：封鎖確認——內容操作表「封鎖{name}」動作選中後的確認卡，
/// 重用 `DeleteConfirmationSheet` 的通用版式（Grabber＋標題＋內文＋危險色外框確認鈕＋取消），
/// 只換 icon（`user-x`→`person.fill.xmark`，同 `DeleteConfirmationSheet.confirmIcon` 文件註解）
/// 與呼叫的 RPC。
///
/// 錯誤碼（`42501`／`23514`）依 LS-152 Notes `VAij1`／`lzod8`——這兩種情況本來就該被「入口依身分
/// 隱藏」擋住（`contentActions(for:...)` 不會對自己顯示封鎖列、`ContentActionsSheet` 也不會讓
/// 未成年身分走到這裡），真的發生時原本沿用 `DeleteConfirmationSheet` 內建的
/// `error.userFacingMessage` 全域兜底文案；**42501 改用專屬文案**（LS-189 R2，merge-review
/// R1 B4）——`DeleteConfirmationSheet` 預設的 42501 映射是「你沒有權限刪除這項內容。」，但
/// `block_user` 的 42501 實際語意是「呼叫者已經不是該家庭成員」（`docs/API.md` §4），畫面說
/// 「沒有權限刪除」動詞完全錯；其餘碼（`23514` 等）仍沿用全域兜底文案，不逐一列舉。
struct BlockConfirmSheet: View {
    let familyID: UUID
    let familyName: String
    let blockedID: UUID
    let memberName: String
    let safetyAPIClient: SafetyAPIClient
    /// RPC 成功、sheet 已關閉之後呼叫——呼叫端可以用它觸發時間軸／相簿／留言重抓，讓被封鎖者
    /// 的內容立即消失（`docs/API.md` §4 `block_user`：「時間軸／留言／相簿三處查詢立即套用，
    /// 不需要額外呼叫任何『重新整理』的 RPC」——重抓是為了讓已經拿到的 client 端快取跟上，
    /// 不是後端要求的動作）。
    var onBlocked: () -> Void = {}

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: "要封鎖「\(memberName)」嗎？",
            bodyText: "封鎖後，你會看不到這位成員的照片、日記與留言；對方不會收到通知，也不受任何影響，" +
                "還是能正常使用「\(familyName)」。你隨時可以在設定裡解除封鎖。",
            confirmLabel: "封鎖這位成員",
            confirmIcon: "person.fill.xmark",
            confirmAction: { try await safetyAPIClient.blockUser(familyID: familyID, blockedID: blockedID) },
            onSuccess: onBlocked,
            errorCopy: { error in
                guard case .rejected(_, let code) = error, code == "42501" else { return error.userFacingMessage }
                return "你沒有權限封鎖這位成員。"
            }
        )
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        BlockConfirmSheet(
            familyID: UUID(), familyName: "陳家", blockedID: UUID(), memberName: "陳志明",
            safetyAPIClient: PreviewSafetyAPIClient()
        )
    }
}
#endif
