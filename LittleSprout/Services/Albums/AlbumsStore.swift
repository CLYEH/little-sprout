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

    private let apiClient: AlbumsAPIClient

    private(set) var albums: [AlbumSummary] = []
    private(set) var refreshState: AlbumsOperationState = .idle
    private(set) var loadMoreState: AlbumsOperationState = .idle
    private(set) var hasMorePages = true
    private(set) var createAlbumState: AlbumsOperationState = .idle

    private var familyID: UUID?
    /// 世代計數器：理由與守門邏輯同 `TimelineStore.generation` 文件註解，這裡不重複。
    private var generation = 0

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
    @discardableResult
    func createAlbum(familyID: UUID, title: String, childIDs: [UUID]) async -> Bool {
        createAlbumState = .submitting
        do {
            let created = try await apiClient.createAlbum(familyID: familyID, title: title)
            if !childIDs.isEmpty {
                try await apiClient.setAlbumChildren(albumID: created.id, childIDs: childIDs)
            }
            createAlbumState = .success
            await refresh(familyID: familyID)
            return true
        } catch {
            createAlbumState = .failure(AppError.map(error))
            return false
        }
    }

    func resetCreateAlbumState() {
        createAlbumState = .idle
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
