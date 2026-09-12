import SwiftUI

/// LS-218：三種卡片共用的「開留言 sheet」這條線——抽到獨立檔案（同
/// `DiaryDetailView+ContentActions.swift` 既有先例：`TimelineView.swift` 本體已經有卡片流／
/// 篩選／分頁三段邏輯，疊上這條會超過 SwiftLint `file_length`／`type_body_length`）。
extension TimelineView {
    /// 不可見的 `EmptyView`，掛留言 sheet 的 `.sheet(item:)`——同 `DiaryDetailView
    /// .contentActionsSheetHost` 既有理由（`.sheet` 掛在樹上哪個節點不影響呈現）。
    var commentsSheetHost: some View {
        EmptyView()
            .sheet(item: $commentsSheetTarget) { target in
                if let familyID = familyStore.myFamily?.id {
                    CommentsSheetView(
                        kind: target.kind, refId: target.refId, familyID: familyID, timelineStore: timelineStore,
                        familyStore: familyStore, childrenStore: childrenStore,
                        commentAPIClient: commentAPIClient, safetyAPIClient: safetyAPIClient
                    )
                }
            }
    }

    /// 三種卡片共用的 `InteractionRow.onOpenComments` 回呼——開留言 sheet（票文 scope 1）。
    func openComments(kind: FeedKind, refId: UUID) {
        commentsSheetTarget = CommentsSheetTarget(kind: kind, refId: refId)
    }

    /// 依 `entry.content` 畫出對應卡片——搬到這個檔案的理由同檔頭註解：三種卡片的
    /// `onOpenComments` 閉包都在這裡組裝，跟這條線密不可分。
    @ViewBuilder
    func cardView(for entry: TimelineEntry, columns: Int) -> some View {
        switch entry.content {
        case .diary(let content):
            NavigationLink(value: TimelineRoute.diaryDetail(entry.refId)) {
                DiaryCardView(
                    content: content, taggedChildren: taggedChildren(for: entry), timelineStore: timelineStore,
                    refId: entry.refId,
                    onOpenComments: { openComments(kind: .diary, refId: entry.refId) },
                    previewRowWidth: max(0, cardOuterWidth(columns: columns) - 2 * AppSpacing.insetCard)
                )
            }
            .buttonStyle(.plain)
            // LS-158：QA e2e 用 identifier 找卡片（整張卡合併成一顆 button，label＝日記本文，會隨內容變）。
            .accessibilityIdentifier(QAAccessibilityID.timelineDiaryCard)
        case .album(let content):
            AlbumCardView(
                content: content, timelineStore: timelineStore, refId: entry.refId,
                onOpenComments: { openComments(kind: .album, refId: entry.refId) }
            )
        case .media(let content):
            PhotoCardView(
                content: content, timelineStore: timelineStore,
                onOpenComments: { openComments(kind: .media, refId: entry.refId) }
            )
        case nil:
            EmptyView()
        }
    }

    private func taggedChildren(for entry: TimelineEntry) -> [Child] {
        childrenStore.children.filter { entry.childIds.contains($0.id) }
    }
}

/// `.sheet(item:)` 需要 `Identifiable`——`id` 用 `TimelineEntry.id(kind:refId:)` 同一套字串鍵
/// （同 `InteractionRow.targetKey` 既有慣例），不是隨機 `UUID`：確保同一個 target 兩次點開留言
/// 鈕拿到「同一個身分」，SwiftUI 才不會誤判成不同的 sheet 而重建。
struct CommentsSheetTarget: Identifiable {
    let kind: FeedKind
    let refId: UUID
    var id: String { TimelineEntry.id(kind: kind, refId: refId) }
}
