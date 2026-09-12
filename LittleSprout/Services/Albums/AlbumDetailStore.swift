import Foundation
import Observation

/// `AlbumDetailStore` 各非同步動作共用的狀態機——同 `AlbumsOperationState`／`TimelineOperationState`
/// 的角色，見該檔文件註解，這裡不重複。
enum AlbumDetailOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 相簿詳情（LS-166，`design/littlesprout.pen` `LS-142 / 15 相簿詳情`）的 `@Observable`
/// 狀態管理——畫面等級的 store（每次推入詳情頁建立一份新的，同 `DiaryComposerStore` 的角色分工，
/// 不像 `AlbumsStore` 那樣隨 app 存活），負責：
///   1. 載入這本相簿的全部照片（`album_media` 連結列 → `media` 列 → 簽名 URL，見 `refresh()`）；
///   2. 「加入照片」上傳成功後、**若使用者還留在這個畫面**，讓照片牆立即出現新格
///      （`reflectUploadedMedia(_:)`）——實際把照片掛進相簿（`album_media` INSERT）已經
///      由 `AlbumsStore.attachUploadedMedia`（app 層存活，不隨這支 View-scoped store 存活
///      與否而定）完成，merge-review R2 M2：這支 store 不再負責寫入，只負責「如果我還在，
///      幫忙即時反映」，見該方法文件註解；
///   3. 編輯相簿名稱＋多寶貝標記（`submitEdit`，見該方法文件註解——兩者合併成單一提交動作，
///      對應「編輯相簿名稱」sheet 同時承載這兩件事，見 `EditAlbumView` 文件註解）。
///   4. 刪除相簿**不**在這支 store——`AlbumDeleteConfirmationSheet` 直接呼叫
///      `AlbumsAPIClient.setAlbumDeleted`，不需要經過這裡的任何狀態（同 `DiaryDeleteConfirmationSheet`
///      直接呼叫 `DiaryAPIClient.setDiaryDeleted` 的既有分工，`DeleteConfirmationSheet` 本身已經有
///      一套完整的 `isSubmitting`／`error` 狀態，這裡疊一份是不必要的重複狀態）。
@MainActor
@Observable
final class AlbumDetailStore {
    let albumID: UUID
    let familyID: UUID
    private let apiClient: AlbumsAPIClient

    private(set) var title: String
    private(set) var childIDs: [UUID]
    private(set) var photos: [MediaContent] = []
    private(set) var loadState: AlbumDetailOperationState = .idle
    private(set) var editState: AlbumDetailOperationState = .idle

    /// `refresh()`／`reflectUploadedMedia(_:)` 交錯呼叫時的世代守門——同 `AlbumsStore.refresh`
    /// 既有設計，理由不重複。
    private var generation = 0

    var photoCount: Int { photos.count }

    init(albumID: UUID, familyID: UUID, title: String, childIDs: [UUID], apiClient: AlbumsAPIClient) {
        self.albumID = albumID
        self.familyID = familyID
        self.title = title
        self.childIDs = childIDs
        self.apiClient = apiClient
    }

    /// 載入（或重新載入）這本相簿的全部照片——不分頁，票文壓測上限 34 張，一次抓齊。
    @discardableResult
    func refresh() async -> Bool {
        generation += 1
        let myGeneration = generation
        loadState = .submitting
        do {
            let links = try await apiClient.fetchAlbumMediaLinks(albumID: albumID)
            let mediaRows = try await apiClient.fetchMedia(ids: links.map(\.mediaId))
            let signed = try await Self.signedURLs(for: mediaRows, apiClient: apiClient)
            let rowsByID = Dictionary(uniqueKeysWithValues: mediaRows.map { ($0.id, $0) })
            let newestFirstLinks = links.sorted { $0.sortOrder > $1.sortOrder }
            let newPhotos = newestFirstLinks.compactMap { link in
                Self.content(for: link.mediaId, in: rowsByID, signed: signed)
            }
            guard myGeneration == generation else { return false }
            photos = newPhotos
            loadState = .success
            return true
        } catch {
            guard myGeneration == generation else { return false }
            guard !Task.isCancelled else {
                loadState = .idle
                return false
            }
            loadState = .failure(AppError.map(error))
            return false
        }
    }

    /// `UploadQueueStore.onUploadSucceeded` 掛鉤的 **UI-only** 收尾（merge-review R2 M2 修正）
    /// ——原本這支方法自己打 `apiClient.attachMedia` 把照片寫進 `album_media`，但呼叫端
    /// （`AlbumDetailView+Actions.makeUploadQueueStore`）弱引用這支 store，使用者在上傳飛行
    /// 中離開詳情頁時 store 會先 deinit，寫入永遠不會發生（media 列建立成功、卻沒有連結，
    /// 見 `AlbumsStore.attachUploadedMedia` 文件註解）。真正的寫入現在由 `AlbumsStore
    /// .attachUploadedMedia`（app 層存活，不隨這支 View-scoped store 存活與否而定）負責，
    /// 保證「上傳成功＝一定掛進相簿」；這裡只在「使用者還留在這個相簿詳情頁」時把新照片插進
    /// 畫面上的 `photos` 陣列，不重複打一次 `attachMedia`（重複打會多一次網路呼叫，且兩邊
    /// 各自現查一次連結數當 `sortOrder`，同時發生時可能算出同一個值）。
    func reflectUploadedMedia(_ mediaID: UUID) async {
        guard let row = (try? await apiClient.fetchMedia(ids: [mediaID]))?.first else { return }
        let signed = (try? await Self.signedURLs(for: [row], apiClient: apiClient)) ?? [:]
        guard let content = Self.content(for: mediaID, in: [mediaID: row], signed: signed) else { return }
        guard !photos.contains(where: { $0.id == content.id }) else { return }
        photos.insert(content, at: 0)
    }

    /// 「編輯相簿名稱」sheet 的單一提交動作（`EditAlbumView`）——名稱與多寶貝標記合併成一次
    /// 提交，只有真的改過的那一半才會打對應的網路請求（未改動的一半維持原值，不重打一次
    /// 語意上的 no-op 請求）。**兩者皆非交易性**（`updateAlbumTitle`／`setAlbumChildren` 是
    /// 兩個獨立呼叫，不像 `AlbumsStore.createAlbum` 那樣需要補償——這裡是編輯既有相簿，前者
    /// 成功、後者失敗時相簿本身仍是合法狀態，只是標記沒改成，不會留下孤兒或半殘留的相簿）。
    /// 兩者權限相同（`docs/API.md` §4：僅建立者本人，且仍是該家庭 owner/member）——
    /// `AlbumDetailView` 把「更多」選單整體限定 owner 可見（依 Notes `OHMPk`），owner
    /// 若不是這本相簿的建立者送出時會收到 `42501`（`setAlbumChildren`）或
    /// `SupabaseAlbumsAPIClient.updateAlbumTitle` 明確轉出的錯誤（merge-review R2 M1——
    /// `albums.title` 直接 `.update()` 原本會靜默影響 0 列，現在已在該實作內把「0 列受影響」
    /// 轉成明確 `AppError`，不再是「靜默 0 列」），`editState.failure` 會呈現對應文案，
    /// 兩者皆不會靜默失敗（Rule 11 fail loud），這個已知落差記入 handoff。
    @discardableResult
    func submitEdit(title newTitle: String, childIDs newChildIDs: [UUID]) async -> Bool {
        editState = .submitting
        do {
            if newTitle != title {
                try await apiClient.updateAlbumTitle(albumID: albumID, title: newTitle)
                title = newTitle
            }
            if newChildIDs != childIDs {
                try await apiClient.setAlbumChildren(albumID: albumID, childIDs: newChildIDs)
                childIDs = newChildIDs
            }
            editState = .success
            return true
        } catch {
            editState = .failure(AppError.map(error))
            return false
        }
    }

    func resetEditState() {
        editState = .idle
    }

    private static func content(
        for mediaID: UUID, in rowsByID: [UUID: MediaRow], signed: [String: URL]
    ) -> MediaContent? {
        guard let row = rowsByID[mediaID] else { return nil }
        return MediaContent(
            id: row.id, type: row.type, width: row.width, height: row.height,
            thumbWidth: row.thumbWidth, thumbHeight: row.thumbHeight,
            storagePath: row.storagePath, isThumbnail: row.thumbPath != nil,
            signedURL: signed[displayPath(row)], durationSeconds: row.durationSeconds
        )
    }

    /// 列表情境要簽的路徑——`thumb_path` 優先、`NULL` 時退回 `storage_path`，同
    /// `TimelineContentAssembler.displayPath` 既有理由（這裡不重複貼一遍，見該檔文件註解）。
    private static func displayPath(_ row: MediaRow) -> String {
        row.thumbPath ?? row.storagePath
    }

    private static func signedURLs(for rows: [MediaRow], apiClient: AlbumsAPIClient) async throws -> [String: URL] {
        guard !rows.isEmpty else { return [:] }
        return try await apiClient.signedURLs(forStoragePaths: rows.map(displayPath))
    }

    #if DEBUG
    /// UI test／harness／`#Preview` 用：直接灌照片，不經過真正的載入流程，同
    /// `AlbumsStore.seedForPreview` 的角色。
    func seedForPreview(photos: [MediaContent]) {
        self.photos = photos
        loadState = .success
    }

    /// Preview／harness 共用建構捷徑——重用 `AlbumsStore.preview()` 已經佈好的假
    /// `AlbumsAPIClient`，不需要另外定義一份重複的 preview stub。
    static func preview(title: String = "上禮拜的動物園一日遊", childIDs: [UUID] = []) -> AlbumDetailStore {
        AlbumDetailStore(
            albumID: UUID(), familyID: UUID(), title: title, childIDs: childIDs,
            apiClient: AlbumsStore.preview().apiClient
        )
    }
    #endif
}
