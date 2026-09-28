import SwiftUI

/// LS-383：時間軸食物卡（`FoodFirstCardView`）的兩個目的地——拆檔理由同 `TimelineView+Comments.swift`
/// （`TimelineView.swift` 本體已貼著 SwiftLint 長度上限）。
///
/// 權限三個值與寶貝詳情的飲食圖鑑入口同一組來源（`ChildrenManagementView.childDetail(for:)`）：
/// `familyStore.ownerUserID`（命名雖是 owner，存的是目前登入者，見該處註解）／`childrenStore.isOwner`／
/// `childrenStore.canManageChildren`。R2（LS-380 併入後）：兩條路都走 LS-380 的 `FoodRecordDetailRouter`
/// （圖鑑那條由 `FoodBookView(recordDetailContext:)` 自己組），詳情頁的編輯／刪除／加照片真的接上 sheet。
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

    /// 整張卡 → 記錄詳情 04。從 `TimelineStore.entries` 依 id 查目前那一筆（同 `.diaryDetail`，見 `TimelineRoute`）；
    /// 存檔／刪除之後重新整理時間軸，卡片跟著換新或消失。
    @ViewBuilder
    private func foodRecordDetailDestination(recordID: UUID) -> some View {
        if let foodAPIClient, let content = foodFirstContent(recordID: recordID),
           let child = childForID(content.record.childID) {
            TimelineFoodRecordDetailHost(
                child: child, item: content.item, initialRecord: content.record, apiClient: foodAPIClient,
                context: recordDetailContext, canRecord: childrenStore.canManageChildren,
                onChanged: refreshAfterFoodRecordChange
            )
        }
    }

    /// Book Row → 圖鑑 02，直接選到那項食物的類別（`FoodBookView(initialCategory:)`）；吃過的格子由圖鑑自己推
    /// `FoodRecordDetailRouter`（`recordDetailContext`）。
    @ViewBuilder
    private func foodBookDestination(childID: UUID, category: FoodCategory) -> some View {
        if let foodAPIClient, let child = childForID(childID) {
            FoodBookView(
                child: child, apiClient: foodAPIClient, canRecord: childrenStore.canManageChildren,
                initialCategory: category, recordDetailContext: recordDetailContext
            )
        }
    }

    private var recordDetailContext: FoodRecordDetailContext {
        FoodRecordDetailContext(currentUserID: familyStore.ownerUserID, isFamilyOwner: childrenStore.isOwner)
    }

    private func refreshAfterFoodRecordChange() {
        guard let familyID = familyStore.myFamily?.id else { return }
        Task { await timelineStore.refresh(familyID: familyID, childID: selectedChildID) }
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

/// 時間軸推入的記錄詳情：握住最新那一筆（03b 存檔回傳列，同 `FoodBookView.recordDetail` 對圖鑑 store 做的事），
/// 刪除（或重讀發現已被刪）就返回時間軸。
private struct TimelineFoodRecordDetailHost: View {
    let child: Child
    let item: FoodCatalogItem
    let initialRecord: ChildFoodRecord
    let apiClient: FoodAPIClient
    let context: FoodRecordDetailContext
    let canRecord: Bool
    let onChanged: () -> Void

    @State private var saved: ChildFoodRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FoodRecordDetailRouter(
            child: child, item: item, record: saved ?? initialRecord, apiClient: apiClient, context: context,
            canRecord: canRecord,
            onSaved: { record in
                saved = record
                onChanged()
            },
            onRemoved: { _ in
                dismiss()
                onChanged()
            }
        )
    }
}
