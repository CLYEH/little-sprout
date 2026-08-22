import Foundation

/// App 的四個頂層導航區塊。
///
/// 這是導航 selection 的**單一來源**：compact 的 `TabView` 與 regular 的
/// `NavigationSplitView` 共用同一份 case 清單、標題與圖示，避免兩套版面各自
/// 維護一份分頁定義而漂移（PLAN §4：導航層事後重寫會牽動每個畫面）。
enum AppSection: CaseIterable, Identifiable {
    case timeline
    case albums
    case children
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: "時間軸"
        case .albums: "相簿"
        case .children: "孩子"
        case .settings: "設定"
        }
    }

    /// SF Symbol 名稱。名稱打錯時 SF Symbols 會靜默回傳 nil、導航列出現空白圖示，
    /// 所以 `AppSectionTests` 會逐一驗證這些名稱真的存在。
    var systemImage: String {
        switch self {
        case .timeline: "clock"
        case .albums: "photo.on.rectangle.angled"
        case .children: "figure.and.child.holdinghands"
        case .settings: "gearshape"
        }
    }
}
