#if DEBUG
import SwiftUI

/// LS-379：飲食圖鑑 02 家族的 harness host——同 `TapTargetGateHarness+Growth.swift` 的拆檔先例。
/// 都不能標 `private`（`TapTargetGateHarness.hostView(for:)` 跨檔案存取不到）。
///
/// 四支都用 `NavigationStack(path:)` 帶一個非空初始路徑、根畫面標題「陳小安」：真實用法是從寶貝詳情
/// （系統標題＝孩子名）推入，這樣系統返回鍵才會是稿面 Nav Back「陳小安」（同
/// `growthRecordsListHost` 的既有技巧），截圖對稿與 tap target 量測都涵蓋返回鍵。
extension TapTargetGateHarness {
    @MainActor
    @ViewBuilder
    static var foodBookHost: some View {
        foodBookStack(FoodBookView(previewStore: .previewSeededWithDemoRecords()))
    }

    /// 02 深色（稿 `XuCDh`）：`.preferredColorScheme(.dark)` 釘住深色，不依賴模擬器外觀設定——
    /// `FoodBookUITests` 在同一台模擬器上淺深各跑一次。
    @MainActor
    @ViewBuilder
    static var foodBookDarkHost: some View {
        foodBookStack(FoodBookView(previewStore: .previewSeededWithDemoRecords()))
            .preferredColorScheme(.dark)
    }

    /// 02b 乳製品（稿 `SYefI`）：鮮奶「含牛奶／一歲後」、布丁「含牛奶等」、優格吃過。
    @MainActor
    @ViewBuilder
    static var foodBookDairyHost: some View {
        foodBookStack(FoodBookView(previewStore: .previewSeededWithDemoRecords(), initialCategory: .dairy))
    }

    /// 02c viewer 唯讀（稿 `jo5h8`）：空位無髮絲框、不是按鈕；提示句換唯讀版。
    @MainActor
    @ViewBuilder
    static var foodBookViewerHost: some View {
        foodBookStack(FoodBookView(previewStore: .previewSeededWithDemoRecords(), canRecord: false))
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
