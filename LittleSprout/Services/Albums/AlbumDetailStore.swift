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
///   2. 「加入照片」上傳成功後即時掛進相簿＋讓照片牆出現新格（`attachUploadedMedia(_:)`，
///      `UploadQueueStore.onUploadSucceeded` 掛鉤的接線端）；
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

    /// `refresh()`／`attachUploadedMedia(_:)` 交錯呼叫時的世代守門——同 `AlbumsStore.refresh`
    /// 既有設計，理由不重複。
    private var generation = 0
    /// `album_media` 沒有時間戳（見 `AlbumMediaLinkRow` 文件註解），詳情頁「新加入的排最前」
    /// 靠 `sortOrder` 由大到小排——這裡用「目前已知連結數」當下一筆的基底，每次 `refresh()`
    /// 重新校準（`links.count`），同一次 session 內連續 `attachUploadedMedia` 多張時遞增，
    /// 不需要為了取「目前最大值」多發一次查詢。
    private var nextSortOrder = 0

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
            nextSortOrder = links.count
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

    /// `UploadQueueStore.onUploadSucceeded` 掛鉤的接線端（LS-166／LS-212 補充：LS-167 交付的
    /// 佇列 store 原本零 production 接線）——上傳成功、拿到新 `media` id 後呼叫，把它掛進這本
    /// 相簿並讓照片牆立即出現新格，不等使用者關掉 sheet 或下拉重新整理。
    ///
    /// **best-effort，不對外拋錯**：真的失敗（例如上傳當下家庭被停權，`album_media` INSERT
    /// 撞 `42501`）時，這張照片已經合法上傳成功、有 `media` 列，只是沒有掛進這本相簿——不是
    /// 孤兒（`media` 列本身合法存在，只是沒有被任何相簿／日記引用，這正是 LS-96 池項
    /// `c2050d43` 描述的「有主但目前未被引用」情境，不在本票清理範圍）；佇列 sheet 已經告訴
    /// 使用者「上傳完成」，這裡再跳一個獨立錯誤會製造「明明說完成了又說失敗」的矛盾體驗——
    /// 記入 handoff「未完成」：使用者不會被明確告知「這張沒有掛進相簿」，只會在照片牆上看不到
    /// 這張（若之後重新整理，`refresh()` 依 `album_media` 真相重建，仍然看不到，因為它真的
    /// 沒有被掛上）。
    func attachUploadedMedia(_ mediaID: UUID) async {
        let sortOrder = nextSortOrder
        nextSortOrder += 1
        do {
            try await apiClient.attachMedia(
                albumID: albumID, familyID: familyID, mediaID: mediaID, sortOrder: sortOrder
            )
        } catch {
            return
        }
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
    /// 若不是這本相簿的建立者送出時會收到 `42501`／`LS045`，`editState.failure` 會呈現
    /// 對應文案，不會靜默失敗（Rule 11 fail loud），這個已知落差記入 handoff。
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
        nextSortOrder = photos.count
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
