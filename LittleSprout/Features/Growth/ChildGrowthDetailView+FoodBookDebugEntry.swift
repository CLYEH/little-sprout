import SwiftUI

/// LS-379：飲食圖鑑（`FoodBookView`）的**暫時**入口——正式入口（寶貝詳情「成長」之後的飲食圖鑑區塊，
/// LS-326 01 家族）是 LS-382。本票只需要「導覽走得到」好做主流程實跑與 QA，不畫任何沒有設計稿的東西。
///
/// 雙重閘：只編進 DEBUG build，且要在 UserDefaults 打開 `LSFoodBookDebugEntry` 才顯示——預設關，
/// 寶貝詳情的版面（LS-252 稿、既有 UI 測試與 QA 截圖）在沒開旗標時完全不變。打開方式（擇一）：
/// - 模擬器常駐：`xcrun simctl spawn <udid> defaults write com.leoyeh.littlesprout LSFoodBookDebugEntry -bool YES`
/// - 單次啟動：launch argument `-LSFoodBookDebugEntry YES`
///
/// 需要 app 根注入的 `\.foodAPIClient`（`LittleSproutApp.rootView`）；harness／preview 沒注入時不顯示。
/// LS-382 落地後整支檔案移除。
extension ChildGrowthDetailView {
    static let foodBookDebugEntryKey = "LSFoodBookDebugEntry"

    @ViewBuilder
    func foodBookDebugEntry() -> some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: Self.foodBookDebugEntryKey), let foodAPIClient {
            NavigationLink {
                FoodBookView(
                    child: child, apiClient: foodAPIClient, canRecord: canManageChildren,
                    // LS-381：吃過的格子推記錄詳情；LS-380 R2：由圖鑑自己組 `FoodRecordDetailRouter`，編輯／刪除／
                    // 加照片的 sheet 與結果回寫（格子狀態、pop）都接上。
                    recordDetailContext: FoodRecordDetailContext(
                        currentUserID: currentUserID, isFamilyOwner: isFamilyOwner
                    )
                )
            } label: {
                Text("飲食圖鑑（開發用入口）")
                    .appFont(.body, weight: .medium)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
        #endif
    }
}
