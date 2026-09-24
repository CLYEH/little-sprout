import SwiftUI

/// `FoodBookView` 的載入失敗兩態——從主檔拆出（`type_body_length`，同 `AlbumDetailView+Actions.swift`
/// 的既有拆檔先例）。不標 `private`：`private` 以檔案為界，跨檔 `extension` 存取不到。
extension FoodBookView {
    /// 首次載入就失敗（沒有任何資料可顯示）：整頁錯誤態——錯誤文案＋「重新載入」，同
    /// `AlbumDetailView.loadFailureState`／`GrowthRecordsListView.failureState` 的既有語彙。不落回全灰的
    /// 格子：那會讓使用者以為孩子什麼都沒吃過。
    func loadFailure(message: String, store: FoodBookStore) -> some View {
        VStack(spacing: AppSpacing.item) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.large)
            Text(message)
                .appFont(.body)
                .multilineTextAlignment(.center)
            reloadButton(store)
        }
        .foregroundStyle(Color.lsTextPrimary)
        .padding(.horizontal, AppSpacing.screenPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 已有資料、重新整理失敗：資料保留、上方加一條錯誤列（同 `ChildGrowthDetailView.failureBanner`）。
    @ViewBuilder
    func refreshFailureBanner(_ store: FoodBookStore) -> some View {
        if case .failure(let error) = store.loadState {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                Text(error.userFacingMessage).appFont(.note)
                Spacer(minLength: 0)
                reloadButton(store)
            }
            .foregroundStyle(Color.lsTextPrimary)
        }
    }

    /// `FoodBookStore.refresh()` 本身以 `isLoading` 防重入，這顆鈕不需要另外 disable（品牌硬約束不
    /// `.disabled(`）。
    private func reloadButton(_ store: FoodBookStore) -> some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Text("重新載入")
                .appFont(.body, weight: .semibold)
                .frame(minHeight: 48)
        }
    }
}

/// LS-379 暫接的目的地——第一次記錄 sheet（LS-380）與記錄詳情（LS-381）尚未實作時的佔位，只顯示
/// 食物名與「由哪張票實作」，沒有任何互動元件。只可能從 DEBUG 暫時入口走到（見
/// `ChildGrowthDetailView+FoodBookDebugEntry.swift`），不會出現在正式使用者面前；兩張票落地後由
/// `FoodBookView` 的呼叫端注入真畫面，這支型別隨之移除。
struct FoodBookPendingDestination: View {
    let item: FoodCatalogItem
    let ticket: String

    var body: some View {
        VStack(spacing: AppSpacing.item) {
            FoodStickerImage(foodID: item.id, size: 96, isGrayscale: false)
            Text(item.nameZh)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("這個畫面由 \(ticket) 實作，尚未完成。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(AppSpacing.screenPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
    }
}
