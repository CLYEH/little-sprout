import SwiftUI

/// LS-189（依 LS-152 稿 `WIyj9`）：Owner 移除內容確認——內容操作表「移除這則內容」動作、以及
/// 檢舉收件匣（07）卡片「移除內容」次動作共用這張確認卡，重用 `DeleteConfirmationSheet` 的通用
/// 版式（icon `trash-2`→`trash`，跟既有「刪除」共用同一個 icon，見 `DeleteConfirmationSheet
/// .confirmIcon` 文件註解）。
///
/// `docs/API.md` §4 `remove_content_as_owner`：「移除成功後，這則內容全部 `status='pending'`
/// 的檢舉一併標記 `resolved`」——從檢舉收件匣呼叫這張卡不需要另外呼叫
/// `SafetyAPIClient.markReportResolved`，RPC 內部已經處理。
struct OwnerRemoveContentConfirmSheet: View {
    let familyName: String
    let targetType: ContentTargetType
    let targetID: UUID
    let safetyAPIClient: SafetyAPIClient
    /// RPC 成功、sheet 已關閉之後呼叫——本地移除（時間軸／檢舉收件匣列表）由呼叫端負責。
    var onRemoved: () -> Void = {}

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: "要移除這則內容嗎？",
            bodyText: "移除後，這則內容會從「\(familyName)」消失，家人都看不到，這則檢舉也會一併標記為已處理。" +
                "這個動作是家庭管理者專屬的管理權限。",
            confirmLabel: "移除這則內容",
            confirmAction: {
                try await safetyAPIClient.removeContentAsOwner(targetType: targetType, targetID: targetID)
            },
            onSuccess: onRemoved
        )
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        OwnerRemoveContentConfirmSheet(
            familyName: "陳家", targetType: .comment, targetID: UUID(), safetyAPIClient: PreviewSafetyAPIClient()
        )
    }
}
#endif
