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

    /// LS-136：`.children` 由「孩子」改「寶貝」——`cmp/Tab Bar` 全字級純 icon 拿掉可見文字後，
    /// tab-root 目的地畫面 display 標題就是唯一的非手勢替代路徑（`entry-conditions.md` ⑬），
    /// 這個字串同時驅動分頁 accessibilityLabel 與（未被 `ChildrenManagementView` 自己覆寫時的）
    /// 導覽列標題，必須跟稿面定案的 tab 名稱「寶貝」逐字一致。
    var title: String {
        switch self {
        case .timeline: "時間軸"
        case .albums: "相簿"
        case .children: "寶貝"
        case .settings: "設定"
        }
    }

    /// SF Symbol 名稱。名稱打錯時 SF Symbols 會靜默回傳 nil、導航列出現空白圖示，
    /// 所以 `AppSectionTests` 會逐一驗證這些名稱真的存在。
    ///
    /// LS-136：`.timeline` 由 `clock`（時間語彙）改 `rectangle.grid.1x2`，對應設計稿
    /// `cmp/Tab Bar` 選用的 lucide `gallery-vertical`（單一直立矩形＋橫線＝一條持續往下
    /// 捲動的 feed，見 `motifs.md`「Tab Bar 全字級純 icon」）；`.albums`／`.children`／
    /// `.settings` 三顆與 lucide `images`／`baby`／`settings` 語意已一致，不動。
    var systemImage: String {
        switch self {
        case .timeline: "rectangle.grid.1x2"
        case .albums: "photo.on.rectangle.angled"
        case .children: "figure.and.child.holdinghands"
        case .settings: "gearshape"
        }
    }
}
