#if DEBUG
import SwiftUI

/// LS-379：飲食圖鑑 02 家族的 harness host——同 `TapTargetGateHarness+Growth.swift` 的拆檔先例。
/// 都不能標 `private`（`TapTargetGateHarness.hostView(for:)` 跨檔案存取不到）。
///
/// 四支都用 `NavigationStack(path:)` 帶一個非空初始路徑、根畫面標題「陳小安」：真實用法是從寶貝詳情
/// （系統標題＝孩子名）推入，這樣系統返回鍵才會是稿面 Nav Back「陳小安」（同
/// `growthRecordsListHost` 的既有技巧），截圖對稿與 tap target 量測都涵蓋返回鍵。
///
/// LS-393：吃過的格子推真的 04 記錄詳情（原本推 LS-381 落地前的佔位頁，型別已刪）——四支都帶
/// `foodBookDetailContext`，假 client 也帶同一批示範記錄（`demoFoodBook`）：詳情頁開啟即重讀，查不到那一筆
/// 會當成已被刪（`isGone`）而自己返回。
extension TapTargetGateHarness {
    /// 飲食圖鑑 harness 共用的詳情頁身分：登入者不是任何一筆的作者、是 owner（04c：只有「刪除」）。
    static let foodBookDetailContext = FoodRecordDetailContext(currentUserID: nil, isFamilyOwner: true)

    @MainActor
    @ViewBuilder
    static var foodBookHost: some View {
        foodBookStack(demoFoodBook())
    }

    /// 02 深色（稿 `XuCDh`）：`.preferredColorScheme(.dark)` 釘住深色，不依賴模擬器外觀設定——
    /// `FoodBookUITests` 在同一台模擬器上淺深各跑一次。
    @MainActor
    @ViewBuilder
    static var foodBookDarkHost: some View {
        foodBookStack(demoFoodBook())
            .preferredColorScheme(.dark)
    }

    /// 02b 乳製品（稿 `SYefI`）：鮮奶「含牛奶／一歲後」、布丁「含牛奶等」、優格吃過。
    @MainActor
    @ViewBuilder
    static var foodBookDairyHost: some View {
        foodBookStack(demoFoodBook(initialCategory: .dairy))
    }

    /// 02c viewer 唯讀（稿 `jo5h8`）：空位無髮絲框、不是按鈕；提示句換唯讀版。
    @MainActor
    @ViewBuilder
    static var foodBookViewerHost: some View {
        foodBookStack(demoFoodBook(canRecord: false))
    }

    /// 示範資料集（`FoodBookStore.demoRecords`）的圖鑑：store 與假 client 共用同一批記錄（同一組 id）。
    @MainActor
    private static func demoFoodBook(
        canRecord: Bool = true, initialCategory: FoodCategory = .grainRoot
    ) -> FoodBookView {
        let childID = UUID()
        let records = FoodBookStore.demoRecords(childID: childID)
        let apiClient = PreviewFoodAPIClient(records: records)
        let store = FoodBookStore(childID: childID, apiClient: apiClient)
        store.seedForPreview(catalog: PreviewFoodCatalog.items, records: records)
        return FoodBookView(
            previewStore: store, canRecord: canRecord, initialCategory: initialCategory, apiClient: apiClient,
            recordDetailContext: foodBookDetailContext
        )
    }

    @MainActor
    private static func foodBookStack(_ book: FoodBookView) -> some View {
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationTitle("陳小安")
                .navigationDestination(for: Bool.self) { _ in book }
        }
    }
}
#endif
