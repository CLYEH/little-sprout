import SwiftUI

/// LS-383：時間軸食物卡（`FoodFirstCardView`）的兩個目的地——拆檔理由同 `TimelineView+Comments.swift`
/// （`TimelineView.swift` 本體已貼著 SwiftLint 長度上限）。
///
/// 權限三個值與寶貝詳情的飲食圖鑑入口同一組來源（`ChildrenManagementView.childDetail(for:)`）：
/// `familyStore.ownerUserID`（命名雖是 owner，存的是目前登入者，見該處註解）／`childrenStore.isOwner`／
/// `childrenStore.canManageChildren`。記錄詳情的編輯／刪除／加照片 sheet 屬 LS-380，`onRoute` 沿用預設
/// no-op（同 `ChildGrowthDetailView+FoodBookDebugEntry.swift`）。
///
/// `\.foodAPIClient` 沒注入（preview／沒種 client 的 harness）時目的地為空——正式 app 由
/// `LittleSproutApp.rootView` 一律注入。
extension TimelineView {
    /// `TimelineView` 的 `.navigationDestination(for: TimelineRoute.self)` 把兩個食物路由整包交過來。
    @ViewBuilder
    func foodDestination(for route: TimelineRoute) -> some View {
        switch route {
        case .foodRecordDetail(let recordID): foodRecordDetailDestination(recordID: recordID)
        case .foodBook(let childID, let category): foodBookDestination(childID: childID, category: category)
        case .diaryDetail: EmptyView()
        }
    }

    /// 整張卡 → 記錄詳情 04。從 `TimelineStore.entries` 依 id 查目前那一筆（同 `.diaryDetail`，見 `TimelineRoute`）。
    @ViewBuilder
    private func foodRecordDetailDestination(recordID: UUID) -> some View {
        if let foodAPIClient, let content = foodFirstContent(recordID: recordID),
           let child = childForID(content.record.childID) {
            recordDetail(child: child, item: content.item, record: content.record, apiClient: foodAPIClient)
        }
    }

    /// Book Row → 圖鑑 02，直接選到那項食物的類別（`FoodBookView(initialCategory:)`）。
    @ViewBuilder
    private func foodBookDestination(childID: UUID, category: FoodCategory) -> some View {
        if let foodAPIClient, let child = childForID(childID) {
            FoodBookView(
                child: child, apiClient: foodAPIClient, canRecord: childrenStore.canManageChildren,
                initialCategory: category,
                recordDetailDestination: { item, record in
                    AnyView(recordDetail(child: child, item: item, record: record, apiClient: foodAPIClient))
                }
            )
        }
    }

    private func recordDetail(
        child: Child, item: FoodCatalogItem, record: ChildFoodRecord, apiClient: FoodAPIClient
    ) -> FoodRecordDetailView {
        FoodRecordDetailView(
            child: child, item: item, record: record, apiClient: apiClient,
            currentUserID: familyStore.ownerUserID, isFamilyOwner: childrenStore.isOwner,
            canRecord: childrenStore.canManageChildren
        )
    }

    private func foodFirstContent(recordID: UUID) -> FoodFirstContent? {
        let entry = timelineStore.entries.first { $0.kind == .foodFirst && $0.refId == recordID }
        guard case .foodFirst(let content) = entry?.content else { return nil }
        return content
    }

    private func childForID(_ id: UUID) -> Child? {
        childrenStore.children.first { $0.id == id }
    }
}
