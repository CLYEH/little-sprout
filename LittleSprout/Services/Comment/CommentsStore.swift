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

    /// merge-review R1 m2：`loadEarlier()`（載入更早的留言）與 `loadInitial()`（封鎖成功／
    /// 重試按鈕觸發，見 `CommentsSheetView+Actions.swift`／`+States.swift`）沒有世代守門時，
    /// `loadEarlier()` 進行中若 `loadInitial()` 換掉整份 `comments`（例如封鎖了某位作者、清單
    /// 改用過濾後的新首頁），稍後才回來的 `loadEarlier()` 舊回應只會拿「新的 `comments`」去算
    /// `existingIDs` 去重，把舊頁（可能含被封鎖者的留言）prepend 回一份已經是新世代的清單，也
    /// 用舊頁筆數覆蓋 `hasEarlier`——同 `TimelineStore.generation` 既有技法：只有「換掉整份
    /// 清單」的 `loadInitial()` 會遞增這個計數，`loadEarlier()` 只讀取＋比對，不遞增（同
    /// `TimelineStore.loadMore()` 不遞增 `generation`、只有 `refresh()` 遞增的既有分工——
    /// `loadInitial()` 才是會換掉 `comments` 這個「base」的操作）。
    ///
    /// **不需要另外加 `TimelineStore.loadMore()` 那種 `baseTailID` 身分核對**——那支額外核對
    /// 存在的理由是「`refresh()` 先開始（世代號先遞增）、`loadMore()` 後開始」這個順序下，
    /// `loadMore()` 捕捉到的世代號其實已經跟 `refresh()` 完成後的世代號相同（見
    /// `TimelineStoreTests.test_loadMore_startedDuringInFlightRefresh_discardsStaleResultsEvenWithSameGeneration`），
    /// 純世代號比對抓不到，需要另外核對 `entries` 的基底身分。這裡不會發生對應的反向順序：
    /// 「载入更早的留言」按鈕只在 `initialLoadState == .success` 且清單非空時渲染（`+List.swift`
    /// `commentsList`）；`loadInitial()` 一旦開始執行，`initialLoadState` 立刻變成
    /// `.submitting`，畫面同一幀切成 `skeletonList`（`+States.swift` `contentArea`），使用者
    /// 在那之後已經按不到「载入更早」——因此「`loadInitial()` 先開始、`loadEarlier()` 後開始」
    /// 這個會讓純世代號比對失效的順序，在這支 View 的實際互動路徑下不可達；反過來「
    /// `loadEarlier()` 先開始、`loadInitial()` 後開始」（m2 描述的封鎖／重試情境）則是
    /// `loadInitial()` 遞增世代號在後，`loadEarlier()` 捕捉到的仍是舊世代號，單純比對即可抓到。
    private var generation = 0

    init(apiClient: CommentAPIClient, familyID: UUID, targetType: String, targetID: UUID) {
        self.apiClient = apiClient
        self.familyID = familyID
        self.targetType = targetType
        self.targetID = targetID
    }

    var commentCount: Int { comments.count }

    func loadInitial() async {
        generation += 1
        let myGeneration = generation
        initialLoadState = .submitting
        do {
            let page = try await apiClient.listComments(
                familyID: familyID, targetType: targetType, targetID: targetID, cursor: nil, limit: Self.pageSize
            )
            guard myGeneration == generation else { return }
            comments = page.reversed()
            hasEarlier = page.count == Self.pageSize
            initialLoadState = .success
        } catch {
            guard myGeneration == generation else { return }
            initialLoadState = .failure(AppError.map(error))
        }
    }

    /// 「載入更早的留言」——`comments.first` 是目前畫面上最舊的一則，拿它的 `(createdAt, id)`
    /// 當下一批的游標（同 `list_comments` 的 keyset 規則：兩個游標參數要嘛都給、要嘛都不給）。
    func loadEarlier() async {
        guard hasEarlier, !loadEarlierState.isSubmitting, let oldest = comments.first else { return }
        let myGeneration = generation
        loadEarlierState = .submitting
        do {
            let cursor = CommentsCursor(createdAt: oldest.createdAt, id: oldest.id)
            let page = try await apiClient.listComments(
                familyID: familyID, targetType: targetType, targetID: targetID, cursor: cursor, limit: Self.pageSize
            )
            // merge-review R1 m2：世代已經被 `loadInitial()` 換過（封鎖成功／重試觸發）——
            // 這批回應是回答一份已經不存在的舊清單，整批丟棄，不寫入 `comments`／`hasEarlier`。
            // `loadEarlierState` 仍要收回 `.idle`（同 `TimelineStore.loadMore()` 的
            // discard-reset 慣例）：`loadInitial()` 不會碰 `loadEarlierState`，這個 in-flight
            // 呼叫自己是唯一有機會把它從 `.submitting` 收回的人，不收的話「載入更早的留言」
            // 鈕會卡在永久轉圈。
            guard myGeneration == generation else {
                loadEarlierState = .idle
                return
            }
            // 防禦性去重（票文「分頁合併去重」）：keyset 分頁理論上不會跟既有頁重疊，這裡仍
            // 用 `id` 過濾——同 `TimelineStore` 系列多處「防禦性去重不是信任伺服器一定不重疊」
            // 的既有哲學。
            let existingIDs = Set(comments.map(\.id))
            let deduped = page.filter { !existingIDs.contains($0.id) }
            comments = deduped.reversed() + comments
            hasEarlier = page.count == Self.pageSize
            loadEarlierState = .success
        } catch {
            guard myGeneration == generation else {
                loadEarlierState = .idle
                return
            }
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
