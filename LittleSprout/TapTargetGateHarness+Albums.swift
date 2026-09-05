#if DEBUG
import SwiftUI

/// LS-165：`AlbumsView`／`CreateAlbumView` 三個 harness host，從 `TapTargetGateHarness.swift`
/// 拆出獨立檔案——加完這三支之後那支檔案超過 SwiftLint `file_length` 上限，理由同
/// `AvatarPrintCard` 從 `CreateChildView.swift` 拆分的既有先例（見該檔文件註解）。
///
/// 三支 host 都不能標 `private`（Swift 的 `private` 以檔案為界，跨檔案的 `extension` 存取
/// 不到）——同 `CreateChildView+Avatar.swift` 拆分後的既有作法，改用預設（internal）存取
/// 層級，範圍仍只在本 module 內，`TapTargetGateHarness.hostView(for:)` 才呼叫得到。
extension TapTargetGateHarness {
    /// LS-165：空狀態畫面唯一的可點元件是 Header 的「新增相簿」建立鈕——不需要任何相簿
    /// seed 資料就有代表性，同 `timelineDefaultStateHost` 的既有理由。`familyStore` 用
    /// `.preview(withFamily:)`（同 `.settings` 案例的既有理由）——不是給 tap-target 量測用
    /// （關閉狀態下量到的元件不受家庭狀態影響），是讓 `AlbumsViewTests`（UITests）能真的點開
    /// 「新增相簿」sheet：`AlbumsView.sheet` 的內容掛在 `if let familyID = familyStore.
    /// myFamily?.id` 底下，`familyStore.myFamily` 是 `nil` 時 sheet 會呈現空白，量不到
    /// `CreateAlbumView` 的表單元件。
    @MainActor
    @ViewBuilder
    static var albumsDefaultStateHost: some View {
        NavigationStack {
            AlbumsView(
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: .preview(), albumsStore: .preview()
            )
        }
    }

    /// LS-165：三張假相簿涵蓋厚度分級三個 tier（1–9／10–49／50+ 張）＋一張零相片
    /// （`.empty` tier，無扇影）——`ChildrenStore` 刻意不 seed（`taggedChildren` 因此對
    /// 每張卡都是空集合，署名列顯示保留高度的空白列，見 `AlbumSignatureFormatter`
    /// 文件註解）：厚度分級與卡片點擊區跟寶貝標記無關，這裡只需要覆蓋「有相簿列表」這個
    /// 狀態本身。`familyStore` 刻意**不** seed 家庭（同 `sectionTabViewWithDiaryHost`
    /// 文件註解的既有理由）：`AlbumsView` 掛上就會跑 `.task(id: familyStore.myFamily?.id)`
    /// 呼叫 `albumsStore.refresh(...)`，若 `myFamily` 非 nil 會真的打
    /// `PreviewAlbumsAPIClient.fetchAlbums`（固定回傳 `[]`）蓋掉上面 seed 的三筆，畫面打回
    /// 空狀態。`myFamily == nil` 時 `.task` 的 guard 直接短路，seed 的資料才留得住。
    @MainActor
    @ViewBuilder
    static var albumsPopulatedStateHost: some View {
        NavigationStack {
            AlbumsView(familyStore: .preview(), childrenStore: .preview(), albumsStore: seededAlbumsStore())
        }
    }

    /// `@ViewBuilder` body 不能塞裸的 void 陳述式（`store.seedForPreview(...)` 這種呼叫會被
    /// `buildExpression` 硬吃成一個 View 表達式而編譯失敗，同 `TapTargetGateHarness.
    /// seededTimelineStore()` 文件註解點名的既有陷阱）——seeding 副作用抽到這支普通函式裡。
    @MainActor
    private static func seededAlbumsStore() -> AlbumsStore {
        let store = AlbumsStore.preview()
        store.seedForPreview(albums: [
            AlbumSummary(
                id: UUID(), title: "上禮拜的動物園一日遊", photoCount: 12, cover: nil, childIds: [],
                createdAt: Date()
            ),
            AlbumSummary(
                id: UUID(), title: "跨年連假出遊", photoCount: 62, cover: nil, childIds: [],
                createdAt: Date().addingTimeInterval(-1)
            ),
            AlbumSummary(
                id: UUID(), title: "新相簿", photoCount: 0, cover: nil, childIds: [],
                createdAt: Date().addingTimeInterval(-2)
            )
        ])
        return store
    }

    /// LS-165：初始態（未填名稱／未選寶貝）就有代表性，`.preview()` 免登入即可建構——同
    /// `createChildHost` 的理由。
    @MainActor
    @ViewBuilder
    static var createAlbumHost: some View {
        CreateAlbumView(familyID: UUID(), albumsStore: .preview(), childrenStore: .preview())
    }
}
#endif
