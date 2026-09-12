import Foundation
import Observation

/// `AlbumsStore` 各非同步動作共用的狀態機，同 `TimelineOperationState`／`ChildOperationState`
/// 的角色。
enum AlbumsOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 相簿 tab 首頁（LS-165）的 `@Observable` 狀態管理，把 `AlbumsAPIClient` 包成畫面能直接讀
/// 狀態驅動重繪的 store——同 `TimelineStore` 之於 `TimelineAPIClient` 的角色，`refresh`／
/// `loadMore` 的世代守門邏輯直接沿用該檔案的既有設計（理由見該檔文件註解，這裡不重複貼一遍）。
@MainActor
@Observable
final class AlbumsStore {
    /// 一頁相簿筆數——沒有後端 SQL 預設值可對齊（沒有 RPC），跟 `TimelineStore.pageSize`
    /// 用同一個數字單純是維持全站列表分頁筆數一致的慣例，不是共用同一份契約。
    static let pageSize = 20

    /// LS-166：從 `private` 改成預設（internal）存取層級——`AlbumDetailView` 建構
    /// `AlbumDetailStore` 需要重用同一個 client 實例（同一份 Supabase session／同一組
    /// preview stub），不需要為此另外把 `AlbumsAPIClient` 往下多傳一層參數（`AlbumsView`／
    /// `RootView` 目前都只認得到 `AlbumsStore`，見該檔）。
    let apiClient: AlbumsAPIClient

    private(set) var albums: [AlbumSummary] = []
    private(set) var refreshState: AlbumsOperationState = .idle
    private(set) var loadMoreState: AlbumsOperationState = .idle
    private(set) var hasMorePages = true
    private(set) var createAlbumState: AlbumsOperationState = .idle

    private var familyID: UUID?
    /// 世代計數器：理由與守門邏輯同 `TimelineStore.generation` 文件註解，這裡不重複。
    private var generation = 0
    /// `createAlbum` 專用世代計數器（merge-review R1 m2）——`createAlbumState` 是獨立於
    /// `albums`／`refreshState`／`loadMoreState` 的另一份 UI 回饋狀態（服務「新增相簿」
    /// sheet 本身），不能共用上面那顆：兩次重疊的 `createAlbum` 呼叫（理論上 sheet 的送出鈕
    /// 在 `isSubmitting` 時已 `.disabled`，這裡是第二道防線，同 `TimelineStore` 一貫「不只靠
    /// UI 擋、狀態機本身也要能擋」的做法）應該讓較舊的一次晚到時不覆蓋較新一次已經寫好的
    /// 結果。
    private var createAlbumGeneration = 0

    init(apiClient: AlbumsAPIClient) {
        self.apiClient = apiClient
    }

    /// 第一頁／換家庭時呼叫——整批換掉 `albums`。
    @discardableResult
    func refresh(familyID: UUID) async -> Bool {
        generation += 1
        let myGeneration = generation
        self.familyID = familyID
        refreshState = .submitting
        do {
            let rows = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: Self.pageSize)
            let newAlbums = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: apiClient)
            guard myGeneration == generation else { return false }
            albums = newAlbums
            hasMorePages = rows.count == Self.pageSize
            refreshState = .success
            return true
        } catch {
            guard myGeneration == generation else { return false }
            guard !Task.isCancelled else {
                refreshState = .idle
                return false
            }
            refreshState = .failure(AppError.map(error))
            return false
        }
    }

    /// 捲到底載入下一頁——游標取自目前最後一筆（`fetchAlbums` 回傳序＝
    /// `created_at desc, id desc`，最後一筆就是最舊的那一筆）。
    @discardableResult
    func loadMore() async -> Bool {
        guard !loadMoreState.isSubmitting, hasMorePages, let familyID, let last = albums.last else { return false }
        let myGeneration = generation
        let baseTailID = last.id
        loadMoreState = .submitting
        do {
            let cursor = AlbumsCursor(createdAt: last.createdAt, id: last.id)
            let rows = try await apiClient.fetchAlbums(familyID: familyID, cursor: cursor, limit: Self.pageSize)
            let newAlbums = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: apiClient)
            guard myGeneration == generation, albums.last?.id == baseTailID else {
                loadMoreState = .idle
                return false
            }
            albums.append(contentsOf: newAlbums)
            hasMorePages = rows.count == Self.pageSize
            loadMoreState = .success
            return true
        } catch {
            guard myGeneration == generation, albums.last?.id == baseTailID else {
                loadMoreState = .idle
                return false
            }
            guard !Task.isCancelled else {
                loadMoreState = .idle
                return false
            }
            loadMoreState = .failure(AppError.map(error))
            return false
        }
    }

    /// 「新增相簿」sheet 送出（票文 Scope 2）：建立相簿→（有標記寶貝才）呼叫
    /// `set_album_children`→成功後整批重新整理第一頁，讓新相簿立即出現在列表最前（`albums`
    /// 依 `created_at desc` 排序，新相簿必定是第一筆，重查一次比自己手動 `insert(at: 0)`
    /// 再另外查一次封面／署名組裝簡單，且能保證跟 `refresh()` 走同一條組裝路徑、不會有兩份
    /// 邏輯之後各自漂移）。
    ///
    /// merge-review R1 M2：`createAlbum`（INSERT）與 `setAlbumChildren`（RPC）是兩個獨立
    /// 網路呼叫，不在同一個資料庫交易裡——第一步成功、第二步失敗時，若什麼都不做，會留下一本
    /// 「建立成功但寶貝標記半途而廢」的相簿，卻仍完整出現在列表上（使用者以為送出失敗，實際
    /// 上相簿已經建立），是資料完整性缺口。修法：第二步失敗時呼叫 `setAlbumDeleted(deleted:
    /// true)` 軟刪剛建立的這一本（補償動作，`try?` 吞掉補償本身的失敗——不能讓「補償失敗」
    /// 蓋掉原本要回報給使用者的錯誤，補償只是盡力而為，不是這次呼叫成敗的一部分），再把
    /// 「設定寶貝標記」失敗的原始錯誤回報給使用者；因為回傳 `false`，`CreateAlbumView.submit()`
    /// 不會 `dismiss()`，sheet 留在畫面上但使用者看到的錯誤訊息與「這本相簿其實已經半殘留在
    /// 資料庫」的事實一致（軟刪後不會出現在列表，不是孤兒）。
    @discardableResult
    func createAlbum(familyID: UUID, title: String, childIDs: [UUID]) async -> Bool {
        createAlbumGeneration += 1
        let myGeneration = createAlbumGeneration
        createAlbumState = .submitting
        do {
            let created = try await apiClient.createAlbum(familyID: familyID, title: title)
            if !childIDs.isEmpty {
                do {
                    try await apiClient.setAlbumChildren(albumID: created.id, childIDs: childIDs)
                } catch {
                    try? await apiClient.setAlbumDeleted(albumID: created.id, deleted: true)
                    guard myGeneration == createAlbumGeneration else { return false }
                    createAlbumState = .failure(AppError.map(error))
                    return false
                }
            }
            guard myGeneration == createAlbumGeneration else { return false }
            createAlbumState = .success
            await refresh(familyID: familyID)
            return true
        } catch {
            guard myGeneration == createAlbumGeneration else { return false }
            createAlbumState = .failure(AppError.map(error))
            return false
        }
    }

    func resetCreateAlbumState() {
        createAlbumState = .idle
    }

    /// merge-review R2 M2：`UploadQueueStore.onUploadSucceeded` 掛鉤的**唯一**寫入端——原本
    /// 掛在 `AlbumDetailStore.attachUploadedMedia`（隨 `AlbumDetailView` 的 `@State` 存活，
    /// pop 掉詳情頁就 deinit），使用者在上傳飛行中離開相簿詳情頁時，完成的照片會建出 `media`
    /// 列，卻永遠沒有 `album_media` 連結（`UploadQueueStore` 自己的飛行中 `Task` 靠
    /// `guard let self` 撐住不會被連帶釋放，但這個掛鉤原本弱引用的 `AlbumDetailStore` 沒有
    /// 任何其他強參照，會先它一步 deinit，掛鉤變成 no-op）。`AlbumsStore` 跟
    /// `TimelineStore`／`ChildrenStore` 同一等級（app 層存活，見檔頭），不隨任何一次進出相簿
    /// 詳情頁的導覽而消失，掛在這裡才能保證「上傳成功＝一定掛進相簿」不看使用者是否還留在
    /// 畫面上。
    ///
    /// **best-effort，不對外拋錯**：理由同舊版 `AlbumDetailStore.attachUploadedMedia` 文件
    /// 註解——真的失敗時（例如上傳當下家庭被停權）這張照片已經合法上傳成功、有 `media` 列，
    /// 只是沒有掛進這本相簿；佇列 sheet 已經告訴使用者「上傳完成」，這裡再跳一個獨立錯誤會
    /// 製造「明明說完成了又說失敗」的矛盾體驗。
    ///
    /// `sortOrder` 現查現算（`fetchAlbumMediaLinks(albumID:).count`）——不像舊版用
    /// `AlbumDetailStore` 那顆跟著單次瀏覽走的記憶體計數器：這裡沒有一個天生綁定「這次上傳
    /// 佇列」的計數器可以沿用，現查一次連結數是唯一不需要額外狀態就能正確算出「接在後面」的
    /// 做法（多裝置／多次瀏覽同時對同一相簿加照片仍可能撞號，同舊版既有風險，不是本票新增的
    /// 退步，見 handoff m4）。
    func attachUploadedMedia(albumID: UUID, familyID: UUID, mediaID: UUID) async {
        do {
            let links = try await apiClient.fetchAlbumMediaLinks(albumID: albumID)
            try await apiClient.attachMedia(
                albumID: albumID, familyID: familyID, mediaID: mediaID, sortOrder: links.count
            )
        } catch {
            return
        }
    }

    /// 登出時歸零——同 `TimelineStore.reset()`／`ChildrenStore` 的角色。
    func reset() {
        albums = []
        refreshState = .idle
        loadMoreState = .idle
        hasMorePages = true
        createAlbumState = .idle
        familyID = nil
        generation += 1
        createAlbumGeneration += 1
    }

    #if DEBUG
    /// UI test／harness 用：`albums` 是 `private(set)`，只能從本檔寫入，同
    /// `TimelineStore.seedForPreview` 的角色與理由。
    @MainActor
    func seedForPreview(albums: [AlbumSummary]) {
        self.albums = albums
        refreshState = .success
        hasMorePages = false
    }
    #endif
}
