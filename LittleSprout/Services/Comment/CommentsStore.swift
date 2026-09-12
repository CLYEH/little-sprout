import Foundation
import Observation

/// `CommentsStore` 各非同步動作共用的狀態機——同 `ChildOperationState`／`FamilyStore.
/// FamilyOperationState`／`TimelineOperationState` 的角色（每個 store 各自持有一份，見那三個
/// 型別的既有先例；本檔同理不共用其中任何一個）。
enum CommentsOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 留言 sheet（LS-218，依 LS-177 稿 `FiBvh` 等七板）的 `@Observable` 狀態管理——單一 target
/// （一則日記／相簿／照片）的留言分頁、樂觀送出、Owner 移除／作者刪除後的本地同步。
///
/// **每次開啟 sheet 建一份新的**（不是像 `TimelineStore` 那樣隨 app 存活的單例）：留言 sheet
/// 關閉後沒有理由保留分頁狀態，下次開啟同一則內容的留言重新查一輪即可（同 `LikersListSheet`
/// 「每次開啟重查一次，不快取」的既有裁量，只是這裡的狀態多到需要一個獨立型別才測得清楚）。
///
/// **keyset 分頁與顯示順序**：`list_comments` 回傳 `created_at DESC, id DESC`（最新在前，同
/// `get_family_timeline` 既有 keyset 慣例）——首頁載入後**反轉**成畫面由舊到新（`FiBvh` 稿面
/// 由上到下是「2 小時前→1 小時前→剛剛」），最新的留言自然落在清單底部，符合聊天串／留言串的
/// 閱讀直覺，也讓「送出後捲到底」等於捲到最新一則。「載入更早的留言」（票文範圍 2）帶上目前
/// `comments.first`（畫面上最舊那一則）的 `(createdAt, id)` 當游標，拿到的下一批同樣反轉後
/// **插到最前面**。
@MainActor
@Observable
final class CommentsStore {
    /// `list_comments` 預設 20（`docs/API.md` §4），與後端預設值一致，不是隨意選的數字——同
    /// `TimelineStore.pageSize` 既有理由。
    static let pageSize = 20

    private let apiClient: CommentAPIClient
    let familyID: UUID
    /// `FeedKind.rawValue`（`"diary"`／`"album"`／`"media"`）——留言掛在哪個內容上，見
    /// `CommentAPIClient` 文件註解「兩個不同的語意軸」。
    let targetType: String
    let targetID: UUID

    private(set) var comments: [CommentRecord] = []
    private(set) var initialLoadState: CommentsOperationState = .idle
    private(set) var loadEarlierState: CommentsOperationState = .idle
    /// 首頁／載入更早那一批回傳筆數等於 `pageSize` 就假定「可能還有更早的」——同
    /// `TimelineStore.hasMorePages` 既有慣例（`pointers.count == Self.pageSize`）。
    private(set) var hasEarlier = true
    private(set) var sendState: CommentsOperationState = .idle

    init(apiClient: CommentAPIClient, familyID: UUID, targetType: String, targetID: UUID) {
        self.apiClient = apiClient
        self.familyID = familyID
        self.targetType = targetType
        self.targetID = targetID
    }

    var commentCount: Int { comments.count }

    func loadInitial() async {
        initialLoadState = .submitting
        do {
            let page = try await apiClient.listComments(
                familyID: familyID, targetType: targetType, targetID: targetID, cursor: nil, limit: Self.pageSize
            )
            comments = page.reversed()
            hasEarlier = page.count == Self.pageSize
            initialLoadState = .success
        } catch {
            initialLoadState = .failure(AppError.map(error))
        }
    }

    /// 「載入更早的留言」——`comments.first` 是目前畫面上最舊的一則，拿它的 `(createdAt, id)`
    /// 當下一批的游標（同 `list_comments` 的 keyset 規則：兩個游標參數要嘛都給、要嘛都不給）。
    func loadEarlier() async {
        guard hasEarlier, !loadEarlierState.isSubmitting, let oldest = comments.first else { return }
        loadEarlierState = .submitting
        do {
            let cursor = CommentsCursor(createdAt: oldest.createdAt, id: oldest.id)
            let page = try await apiClient.listComments(
                familyID: familyID, targetType: targetType, targetID: targetID, cursor: cursor, limit: Self.pageSize
            )
            // 防禦性去重（票文「分頁合併去重」）：keyset 分頁理論上不會跟既有頁重疊，這裡仍
            // 用 `id` 過濾——同 `TimelineStore` 系列多處「防禦性去重不是信任伺服器一定不重疊」
            // 的既有哲學。
            let existingIDs = Set(comments.map(\.id))
            let deduped = page.filter { !existingIDs.contains($0.id) }
            comments = deduped.reversed() + comments
            hasEarlier = page.count == Self.pageSize
            loadEarlierState = .success
        } catch {
            loadEarlierState = .failure(AppError.map(error))
        }
    }

    /// 送出留言——樂觀插入（暫時 `id`，立即出現在清單底部＋捲到底）＋失敗回滾＋成功後把暫時
    /// `id` 換成伺服器回傳的真正 `id`（`create_comment` 只回傳 `id`，不回傳完整列，見
    /// `CommentAPIClient` 文件註解）。空白（去除頭尾空白後）直接短路，不送出、不觸碰
    /// `sendState`——同輸入列送出鈕 `disabled`（空白時本來就按不下去）的雙重保險，防禦性處理
    /// 程式化呼叫（例如 UITest）繞過按鈕直接呼叫這支的情況。
    ///
    /// - Returns: 是否真的送出成功（呼叫端用來決定要不要清空輸入框並捲到底）。
    @discardableResult
    func send(body: String, authorID: UUID, authorDisplayName: String) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        sendState = .submitting
        let optimisticID = UUID()
        let optimistic = CommentRecord(
            id: optimisticID, authorID: authorID, authorDisplayName: authorDisplayName,
            body: trimmed, createdAt: Date()
        )
        comments.append(optimistic)
        do {
            let newID = try await apiClient.createComment(
                familyID: familyID, targetType: targetType, targetID: targetID, body: trimmed
            )
            if let index = comments.firstIndex(where: { $0.id == optimisticID }) {
                comments[index] = CommentRecord(
                    id: newID, authorID: authorID, authorDisplayName: authorDisplayName,
                    body: trimmed, createdAt: optimistic.createdAt
                )
            }
            sendState = .idle
            return true
        } catch {
            comments.removeAll { $0.id == optimisticID }
            sendState = .failure(AppError.map(error))
            return false
        }
    }

    /// Owner 移除／作者刪除成功後——本地立即移除（不等下一次 `loadInitial`），同
    /// `DiaryDetailView+ContentActions.contentRemoved()` 的既有分工。
    func removeLocally(commentID: UUID) {
        comments.removeAll { $0.id == commentID }
    }

    #if DEBUG
    /// 只給 `#Preview`／`TapTargetGateHarness`／UITest harness 用：同步種子留言清單，不必真的
    /// 走一次 async `loadInitial()`——同 `TimelineStore.seedForPreview` 的角色與圍欄理由。
    func seedForPreview(_ seeded: [CommentRecord]) {
        comments = seeded
        initialLoadState = .success
        hasEarlier = false
    }
    #endif
}
