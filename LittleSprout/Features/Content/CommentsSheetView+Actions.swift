import SwiftUI

/// LS-218：留言列點選後的操作表整條流程——抽到獨立檔案（同 `DiaryDetailView+ContentActions.swift`
/// 既有先例：`CommentsSheetView.swift` 本體已經有版面／分頁／輸入列三段邏輯，疊上這條流程會
/// 超過 SwiftLint `file_length`）。
///
/// 流程：點選留言列 →（同步，`comment.authorID`／`comment.authorDisplayName` 已經在
/// `list_comments` 回傳裡，不像 `DiaryDetailView` 需要額外非同步查作者）`commentRowActions(...)`
/// 算好動作列 → `ContentActionsSheet`（沿用 LS-189 元件本體，動作組成依 `DUyg3` 稿面另外裁決，
/// 見 `commentRowActions` 文件註解）→ 依選的動作分流：
///   - 檢舉 → `ReportReasonSheet`（LS-189 05b）→ `ReportSentSheet`（05c）
///   - 封鎖 → `BlockConfirmSheet`（05d）→ 成功後重新整理留言清單（票文範圍 6：被封鎖者留言
///     伺服器端已濾，重查一次讓清單跟上）
///   - Owner 移除 → `OwnerRemoveContentConfirmSheet`（05e，`targetType: .comment`）→ 成功後
///     本地移除＋同步計數
///   - 作者刪除 → 既有 `CommentDeleteConfirmationSheet`（LS-190）→ 成功後本地移除＋同步計數
///
/// 每一步都遵守 `DeleteConfirmationSheet` 定下的既有規約（LS-190 R2 m3）：sheet 自己先
/// `dismiss()`，才呼叫成功回呼。
extension CommentsSheetView {
    var commentActionsSheetHost: some View {
        EmptyView()
            .sheet(item: $actionsContext) { context in
                ContentActionsSheet(
                    headline: quotedHeadline(for: context.comment), actions: context.actions,
                    onSelect: { action in handleCommentAction(action, context: context) }
                )
            }
            .sheet(item: $reportFlowTarget) { target in
                ReportReasonSheet(
                    familyName: familyName, familyID: target.familyID, targetType: target.type, targetID: target.id,
                    safetyAPIClient: safetyAPIClient, onSent: { showsReportSent = true }
                )
            }
            .sheet(isPresented: $showsReportSent) {
                ReportSentSheet(familyName: familyName)
            }
            .sheet(item: $blockConfirmContext) { context in
                BlockConfirmSheet(
                    familyID: familyID, familyName: familyName, blockedID: context.memberID,
                    memberName: context.memberName, safetyAPIClient: safetyAPIClient, onBlocked: memberBlocked
                )
            }
            .sheet(item: $removeConfirmTarget) { target in
                OwnerRemoveContentConfirmSheet(
                    familyName: familyName, targetType: target.type, targetID: target.id,
                    safetyAPIClient: safetyAPIClient, onRemoved: { commentRemoved(target.id) }
                )
            }
            .sheet(item: $deleteConfirmTarget) { target in
                CommentDeleteConfirmationSheet(
                    commentID: target.commentID, commentAPIClient: commentAPIClient,
                    onDeleted: { commentRemoved(target.commentID) }
                )
            }
    }

    private func handleCommentAction(_ action: ContentAction, context: CommentActionsContext) {
        let comment = context.comment
        switch action {
        case .report:
            reportFlowTarget = ContentActionTarget(
                type: .comment, id: comment.id, familyID: familyID, headline: quotedHeadline(for: comment)
            )
        case .block(let memberID, let memberName):
            blockConfirmContext = CommentBlockConfirmContext(memberID: memberID, memberName: memberName)
        case .removeAsOwner:
            removeConfirmTarget = ContentActionTarget(
                type: .comment, id: comment.id, familyID: familyID, headline: quotedHeadline(for: comment)
            )
        case .deleteOwn:
            deleteConfirmTarget = CommentDeleteTarget(commentID: comment.id)
        }
    }

    /// 點選留言列——同步組動作列（`comment.authorID`／`comment.authorDisplayName` 已經在
    /// `list_comments` 回傳裡，不需要像 `DiaryDetailView.openContentActions()` 那樣先非同步查
    /// 一次作者）。
    func rowTapped(_ comment: CommentRecord) {
        guard let viewerUserID = familyStore.ownerUserID, let viewerRole = childrenStore.myRole else { return }
        let actions = commentRowActions(
            authorID: comment.authorID, authorDisplayName: comment.authorDisplayName,
            viewerRole: viewerRole, viewerUserID: viewerUserID
        )
        actionsContext = CommentActionsContext(comment: comment, actions: actions)
    }

    /// `ContentActionsSheet`／`OwnerRemoveContentConfirmSheet` 的 Head Title——同
    /// `DiaryDetailView.openContentActions()` 用 `DiaryDeleteConfirmationCopy.excerpt(from:)`
    /// 組引言的既有手法，這裡重用同一支通用截斷函式（留言與日記內文都是「一段文字」，截斷規則
    /// 沒有理由分兩套）。
    func quotedHeadline(for comment: CommentRecord) -> String {
        "「\(DiaryDeleteConfirmationCopy.excerpt(from: comment.body))」"
    }

    /// Owner 移除／作者刪除成功後——本地立即移除（`CommentsStore.removeLocally`），`.onChange(
    /// of: store.commentCount)` 會自動把新筆數同步回互動列，這裡不需要額外呼叫。
    func commentRemoved(_ commentID: UUID) {
        store.removeLocally(commentID: commentID)
    }

    /// 封鎖成功後收尾（票文範圍 6）：被封鎖者的留言伺服器端已經濾掉，重新整理一次讓這個 sheet
    /// 的清單跟上——不像 `DiaryDetailView.memberBlocked()` 那樣 `dismiss()`，封鎖的是留言的
    /// 作者，不是這個 sheet 掛的內容本身，留在原地繼續看其他留言才合理。
    func memberBlocked() {
        Task { await store.loadInitial() }
    }
}

/// `ContentActionsSheet`（LS-189 05）呈現用的 item——把算好的動作列跟留言綁在一起。
struct CommentActionsContext: Identifiable {
    let comment: CommentRecord
    let actions: [ContentAction]
    var id: UUID { comment.id }
}

/// `BlockConfirmSheet`（05d）呈現用的 item。
struct CommentBlockConfirmContext: Identifiable {
    let memberID: UUID
    let memberName: String
    var id: UUID { memberID }
}

/// `CommentDeleteConfirmationSheet`（LS-190）呈現用的 item——`UUID` 本身不是 `Identifiable`，
/// `.sheet(item:)` 需要包一層。
struct CommentDeleteTarget: Identifiable {
    let commentID: UUID
    var id: UUID { commentID }
}
