#if DEBUG
import SwiftUI

/// LS-165：`AlbumsView`／`CreateAlbumView` 三個 harness host，從 `TapTargetGateHarness.swift`
/// 拆出獨立檔案——加完這三支之後那支檔案超過 SwiftLint `file_length` 上限，理由同
/// `AvatarPrintCard` 從 `CreateChildView.swift` 拆分的既有先例（見該檔文件註解）。LS-166 起
/// 追加 `AlbumDetailView`（owner／member 兩態）與 `EditAlbumView` 三支 host，同一檔案繼續放。
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
                childrenStore: .preview(), albumsStore: .preview(), mediaUploadService: PreviewMediaUploadService()
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
            AlbumsView(
                familyStore: .preview(), childrenStore: .preview(), albumsStore: seededAlbumsStore(),
                mediaUploadService: PreviewMediaUploadService()
            )
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

    /// LS-166：相簿詳情 owner 視角——`AlbumDetailStore` 走真正的 `.task(id:)`（apiClient 是
    /// `PreviewAlbumsAPIClient`，`fetchAlbumMediaLinks` 固定回傳 `[]`），畫面落在空狀態；
    /// 已足夠量測 Nav Row（返回鍵／更多選單）與 Action Bar（加入照片）三顆可點元件的熱區——
    /// 照片牆本身無互動元件（見 `tap-target-exemptions.txt` `AlbumPhotoGridView` 具名排除），
    /// 不需要真的餵假相簿資料才有代表性，同 `.albumsDefaultState` 的既有理由。
    @MainActor
    @ViewBuilder
    static var albumDetailOwnerHost: some View {
        let albumsStore = seededSingleAlbumStore()
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return NavigationStack {
            AlbumDetailView(
                albumID: Self.albumDetailPreviewAlbumID, albumsStore: albumsStore,
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: childrenStore, mediaUploadService: PreviewMediaUploadService()
            )
        }
    }

    /// LS-166：member 視角——「更多」選單不該渲染（`AlbumDetailView` 文件註解「更多僅 owner
    /// 可見」），讓 `AlbumDetailViewTests` 能斷言這件事，不只測 owner 那一半（同
    /// `.settingsMemberRole` 的既有先例）。
    @MainActor
    @ViewBuilder
    static var albumDetailMemberHost: some View {
        let albumsStore = seededSingleAlbumStore()
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.member)
        return NavigationStack {
            AlbumDetailView(
                albumID: Self.albumDetailPreviewAlbumID, albumsStore: albumsStore,
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: childrenStore, mediaUploadService: PreviewMediaUploadService()
            )
        }
    }

    private static let albumDetailPreviewAlbumID = UUID()

    @MainActor
    private static func seededSingleAlbumStore() -> AlbumsStore {
        let store = AlbumsStore.preview()
        store.seedForPreview(albums: [
            AlbumSummary(
                id: albumDetailPreviewAlbumID, title: "上禮拜的動物園一日遊", photoCount: 0, cover: nil,
                childIds: [], createdAt: Date()
            )
        ])
        return store
    }

    /// LS-166：初始態（標題已預填目前相簿名稱）就有代表性，`.preview()` 免登入即可建構——同
    /// `createAlbumHost` 的理由。
    @MainActor
    @ViewBuilder
    static var editAlbumHost: some View {
        EditAlbumView(detailStore: .preview(), childrenStore: .preview())
    }

    /// LS-166：相簿詳情「有照片」視角——`PreviewAlbumsAPIClient`（`.preview()` 系列共用的
    /// 空狀態 stub）對 `fetchAlbumMediaLinks` 固定回傳 `[]`，量不到瀑布流版面本身；這裡改用
    /// `AlbumDetailScreenshotAPIClient`（見該型別文件註解）餵一批真實比例混排的假照片，讓
    /// `AlbumDetailView` 自己的 `.task(id:)` → `refresh()` 走真實流程也能渲染出瀑布流，供
    /// QA／設計對稿截圖使用（不透過外部直接塞 `AlbumDetailStore.seedForPreview`——那樣需要
    /// 改 `AlbumDetailView` 的 init 簽名才能從外部注入已建好的 store，多一個生產程式碼的
    /// 測試專用參數，見票文 handoff「產出位置」對這支 host 的引用）。
    @MainActor
    @ViewBuilder
    static var albumDetailPopulatedHost: some View {
        let albumsStore = AlbumsStore(apiClient: AlbumDetailScreenshotAPIClient(photoCount: 12))
        let albumID = UUID()
        albumsStore.seedForPreview(albums: [
            AlbumSummary(
                id: albumID, title: "阿公阿嬤家過年", photoCount: 12, cover: nil, childIds: [], createdAt: Date()
            )
        ])
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return NavigationStack {
            AlbumDetailView(
                albumID: albumID, albumsStore: albumsStore,
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: childrenStore, mediaUploadService: PreviewMediaUploadService()
            )
        }
    }

    /// LS-166 票文範圍 3：34 張壓測（`FPaFl`）——同 `.albumDetailPopulatedHost`，只是張數不同。
    @MainActor
    @ViewBuilder
    static var albumDetailStressHost: some View {
        let albumsStore = AlbumsStore(apiClient: AlbumDetailScreenshotAPIClient(photoCount: 34))
        let albumID = UUID()
        albumsStore.seedForPreview(albums: [
            AlbumSummary(
                id: albumID, title: "34 張全滿壓測", photoCount: 34, cover: nil, childIds: [], createdAt: Date()
            )
        ])
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return NavigationStack {
            AlbumDetailView(
                albumID: albumID, albumsStore: albumsStore,
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: childrenStore, mediaUploadService: PreviewMediaUploadService()
            )
        }
    }
}

/// LS-166：`albumDetailPopulatedHost`／`albumDetailStressHost` 專用假 `AlbumsAPIClient`——
/// `fetchAlbumMediaLinks`／`fetchMedia`／`signedURLs` 回傳固定數量、比例循環（4:3／1:1／3:4／
/// 兩個 Notes 樣本比例，見 `AlbumPhotoGridLayoutTests` 對應測試）的假照片，讓瀑布流版面在
/// 截圖時看得出真實比例混排的效果；不簽真的 URL（`signedURL` 全部回 `nil`，格內顯示灰底
/// 占位圖——版面幾何只依賴 `width`／`height`，不需要真的載入圖片就能驗證欄寬／corner／
/// 白邊是否正確）。其餘方法皆為 no-op（這個 host 不測試建立／編輯／刪除相簿）。
final class AlbumDetailScreenshotAPIClient: AlbumsAPIClient, @unchecked Sendable {
    private let photoCount: Int
    private let mediaIDs: [UUID]
    private let dimensionsByID: [UUID: (width: Int, height: Int)]

    /// Notes `kHDk4` `k3jJ5j`／`vfPjM` 五組樣本比例（4:3 橫式／1:1／3:4 直式／兩個混合值），
    /// 循環套用湊出 `photoCount` 張，確保截圖能看到真實比例混排而不是同一種形狀重複。
    private static let sampleDimensions: [(width: Int, height: Int)] = [
        (400, 300), (300, 300), (300, 400), (390, 195), (280, 400)
    ]

    init(photoCount: Int) {
        self.photoCount = photoCount
        let ids = (0..<photoCount).map { _ in UUID() }
        mediaIDs = ids
        var dimensions: [UUID: (width: Int, height: Int)] = [:]
        for (index, id) in ids.enumerated() {
            dimensions[id] = Self.sampleDimensions[index % Self.sampleDimensions.count]
        }
        dimensionsByID = dimensions
    }

    func fetchAlbums(familyID: UUID, cursor: AlbumsCursor?, limit: Int) async throws -> [AlbumListingRow] { [] }
    func fetchAlbumChildren(albumIds: [UUID]) async throws -> [AlbumChildLinkRow] { [] }
    func createAlbum(familyID: UUID, title: String) async throws -> AlbumListingRow {
        AlbumListingRow(id: UUID(), title: title, coverMediaId: nil, createdAt: Date())
    }
    func setAlbumChildren(albumID: UUID, childIDs: [UUID]) async throws {}
    func setAlbumDeleted(albumID: UUID, deleted: Bool) async throws {}
    func updateAlbumTitle(albumID: UUID, title: String) async throws {}
    func attachMedia(albumID: UUID, familyID: UUID, mediaID: UUID, sortOrder: Int) async throws {}
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { [:] }

    func fetchAlbumMediaLinks(albumID: UUID) async throws -> [AlbumMediaLinkRow] {
        mediaIDs.enumerated().map { index, id in
            AlbumMediaLinkRow(albumId: albumID, mediaId: id, sortOrder: index)
        }
    }

    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] {
        ids.compactMap { id in
            guard let dimensions = dimensionsByID[id] else { return nil }
            return MediaRow(
                id: id, storagePath: "screenshot/\(id).jpg", type: .photo, width: dimensions.width,
                height: dimensions.height, thumbPath: nil, thumbWidth: nil, thumbHeight: nil, durationSeconds: nil
            )
        }
    }
}
#endif
