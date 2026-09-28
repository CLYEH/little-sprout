import SwiftUI

/// LS-382：寶貝詳情「成長」之後的飲食圖鑑入口（`FoodBookEntrySection`，LS-326 01 家族）——取代 LS-379 的
/// DEBUG 暫時入口。
///
/// **store 生命週期**同 `growthStore`（檔頭「`growthStore` 生命週期」段）：`.task(id: child.id)` 內只在
/// `FoodBookStore.needsRebuild` 判定要重建時才換一顆——同一個孩子 parent 重繪不清空重讀；換孩子（iPad 側欄切
/// `selectedChildID`）才重建。`foodBookSection()` 用 `foodStore.childID == child.id` 決定要不要渲染：換孩子那一
/// 瞬間舊 store 還在，不會把 A 孩子的三格畫在 B 孩子名下。舊 store 還在飛的 `refresh()` 寫回的是舊物件，不影響新的。
extension ChildGrowthDetailView {
    @ViewBuilder
    func foodBookSection() -> some View {
        if let foodAPIClient, let foodStore, foodStore.childID == child.id {
            FoodBookEntrySection(
                child: child, store: foodStore, apiClient: foodAPIClient, canRecord: canManageChildren,
                recordDetailContext: FoodRecordDetailContext(currentUserID: currentUserID, isFamilyOwner: isFamilyOwner)
            )
        }
    }

    @MainActor
    func loadFoodIfNeeded() async {
        guard let foodAPIClient, FoodBookStore.needsRebuild(current: foodStore, forChildID: child.id) else { return }
        let store = FoodBookStore(childID: child.id, apiClient: foodAPIClient)
        foodStore = store
        await store.refresh()
    }
}
