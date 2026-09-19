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

/// LS-237：`AlbumsStore.detailStoreByAlbumID` 的 value——`weak` 讓 `AlbumDetailView` 離開
/// 畫面、`AlbumDetailStore` 自然 deinit 後，這裡的查找跟著落空，不需要另外處理「離開」事件。
private struct WeakAlbumDetailStoreRef {
    weak var store: AlbumDetailStore?
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

    /// LS-303 R4（merge-review R3 M1／M2，orchestrator 裁決 `8579e30e`）：「加入照片」單張
    /// 即傳與批次匯入過渡管線共用的 app 層級 `UploadQueueStore`——完整理由與併發／生命週期
    /// 問題見 `AlbumsStore+SharedUploadQueue.swift` 檔頭文件註解。兩個屬性不標 `private`
    /// （同 `AlbumDetailView` 既有慣例）：那支擴充檔要跨檔案讀寫。
    var sharedUploadQueueStoreInstance: UploadQueueStore?
    /// entry id（`PendingUpload.id`）→ 這筆完成後要掛進哪本相簿，見上。
    var pendingUploadAlbumIDs: [UUID: UUID] = [:]
    /// LS-328：`LittleSproutApp.init()` 唯一寫入點——`sharedUploadQueueStore` 的
    /// `onUploadSucceeded` 掛鉤用它通知時間軸批次匯入完成，見該檔文件註解。`weak`（同
    /// `detailStoreByAlbumID` 既有理由）：`AlbumsStore` 不需要延長 `TimelineStore` 的壽命，
    /// 兩者都是 app 層級全程存活，沒有誰依賴誰活得更久的關係。
    weak var timelineStore: TimelineStore?

    /// LS-237 修（池 `4fafaa19`(a)）：每本相簿下一個要用的 `sortOrder`，`.pending` 是「正在
    /// 打第一次 `fetchMaxSortOrder` 查詢、還不知道基底值」、`.ready` 是「已經知道基底，之後
    /// 都是同步遞增」（`acquiredAt` 見 `sortOrderCursorIdleTTL` 文件註解）——見
    /// `nextSortOrder(forAlbum:)` 文件註解。
    ///
    /// LS-246（票文範圍 3，池 `430a34a1` n1）：`.pending` 多帶一個 `id`——`nextSortOrder` 的
    /// `catch` 收到失敗時，只有「現在字典裡的 `.pending` 仍然是自己剛才在等的那一筆」（id
    /// 相符）才可以清空；只看 case 是不是 `.pending`（不核對是哪一個 `Task`）會誤清掉另一個
    /// 交錯呼叫端剛建立、還在飛行中的全新查詢，見該方法文件註解。
    private enum SortOrderCursor {
        case pending(id: UUID, task: Task<Int?, Error>)
        case ready(next: Int, acquiredAt: Date)
    }
    private var sortOrderCursors: [UUID: SortOrderCursor] = [:]

    /// R2 修（merge-review R1 F3 minor）：`.ready` cursor 原本只在 `reset()`（登出）才清除，
    /// 同一個 app session 可能橫跨數小時——這段時間內若別的裝置也對同一本相簿加了照片，
    /// 這裡快取的基底沒有機會發現，下一次同步遞增算出的值可能跟別的裝置撞號（現查現算的
    /// 舊版每次都重新讀連結數，不會有這個問題）。改成「閒置超過這個秒數就視為這批上傳已經
    /// 結束」，下一次呼叫時重新查一次。
    ///
    /// LS-246（票文範圍 4，池 `430a34a1` n2）：TTL 改以**取得時刻**（`acquiredAt`，查到基底
    /// 值那一刻，之後不再更新）判過期，不是原本 R2 版「使用時刻」（每次讀或寫都把時間戳更新成
    /// 現在）——原本的寫法只要這本相簿在 60 秒內至少用過一次 cursor，時間戳就會一直被推遲，
    /// 一段活躍但拖得很長（例如持續數分鐘、每隔幾秒加一張）的上傳過程會讓同一個基底值被沿用
    /// 到超過原本設計的 60 秒視窗，別的裝置在這段期間加的照片依然偵測不到。改成固定從「查到
    /// 基底值那一刻」算 60 秒，不管期間用了幾次，時間到了下一次呼叫就會重新查一次；同一批次
    /// （幾秒到幾十秒內接續上傳）通常在 60 秒內就會結束，不受影響。
    private static let sortOrderCursorIdleTTL: TimeInterval = 60
    /// 可注入的時鐘——同 `UploadQueueStore.now` 既有先例，測試才能不真的等 60 秒就驗證 TTL。
    private let now: @MainActor () -> Date

    /// LS-237 修（池 `4fafaa19`(b)）：`attachUploadedMedia` 寫入成功後，呼叫「目前是誰在看這本
    /// 相簿」的 `AlbumDetailStore`（若有）——不是「上傳當下捕捉到哪一份」，見
    /// `subscribeDetailStore(albumID:_:)` 文件註解。
    private var detailStoreByAlbumID: [UUID: WeakAlbumDetailStoreRef] = [:]
    /// `createAlbum` 專用世代計數器（merge-review R1 m2）——`createAlbumState` 是獨立於
    /// `albums`／`refreshState`／`loadMoreState` 的另一份 UI 回饋狀態（服務「新增相簿」
    /// sheet 本身），不能共用上面那顆：兩次重疊的 `createAlbum` 呼叫（理論上 sheet 的送出鈕
    /// 在 `isSubmitting` 時已 `.disabled`，這裡是第二道防線，同 `TimelineStore` 一貫「不只靠
    /// UI 擋、狀態機本身也要能擋」的做法）應該讓較舊的一次晚到時不覆蓋較新一次已經寫好的
    /// 結果。
    private var createAlbumGeneration = 0

    init(apiClient: AlbumsAPIClient, now: @escaping @MainActor () -> Date = Date.init) {
        self.apiClient = apiClient
        self.now = now
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

    /// LS-315 R3（merge-review R2 m1／m2）：時間軸「匯入」入口點擊時的補載守門——`albums`
    /// 還沒載過（空）且沒有另一次 `refresh` 正在飛行中才打。下沉到這裡而不是留在呼叫端的
    /// 原始碼字面守衛，理由：(1) 呼叫端只是「點擊時偶爾要補載」，守門邏輯本身屬於
    /// `AlbumsStore` 該不該重打 RPC 的狀態機決定，跟 `loadMore` 開頭的 `!loadMoreState
    /// .isSubmitting` 是同一類判斷；(2) 這裡能用既有 `StubAlbumsAPIClient` 寫真行為測試
    /// （`AlbumsStoreTests`），不必像原本的呼叫端字面守衛只能靠原始碼字串比對。
    @discardableResult
    func refreshIfEmpty(familyID: UUID) async -> Bool {
        guard albums.isEmpty, !refreshState.isSubmitting else { return false }
        return await refresh(familyID: familyID)
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
    /// LS-237 修（池 `4fafaa19`(a)）：`sortOrder` 原本現查現算（`fetchAlbumMediaLinks
    /// (albumID:).count`）——每張上傳完成都是一次無 `.limit()` 的全量連結讀，且
    /// `UploadQueueStore.maxConcurrentUploads = 3` 同批完成的幾張幾乎同時讀到同一個
    /// count（查詢與使用之間隔著一次網路 `await`，多次呼叫可以在等待期間交錯執行），整批
    /// 寫入同一個 `sortOrder`、批內順序退化成 `mediaId` 字典序。改成 `nextSortOrder
    /// (forAlbum:)`：只在這本相簿本地還沒快取過基底時打一次 `fetchMaxSortOrder`，之後都是
    /// 同步遞增（多裝置／多次瀏覽同時對同一相簿加照片仍可能撞號，跨裝置無法只靠 client 端
    /// 保證原子性，見 handoff 記 LS-96）。
    func attachUploadedMedia(albumID: UUID, familyID: UUID, mediaID: UUID) async {
        do {
            let sortOrder = try await nextSortOrder(forAlbum: albumID)
            try await apiClient.attachMedia(
                albumID: albumID, familyID: familyID, mediaID: mediaID, sortOrder: sortOrder
            )
        } catch {
            return
        }
        // LS-237 修（池 `4fafaa19`(b)）：不再倚賴呼叫端（`AlbumDetailView+Actions
        // .makeUploadQueueStore`）自己捕捉到的 `[weak detailStore]`——那份參照是「上傳當下
        // 使用者留在哪個畫面」，使用者若在上傳飛行中離開再進同一本相簿，`AlbumDetailView
        // .task(id:)` 會建一個全新的 `AlbumDetailStore` 實例，舊參照早已失效、沒有第二個
        // 觸發點讓新的那份反映後續完成的照片（見池項原文）。這裡直接查「目前是誰在看這本
        // 相簿」（`subscribeDetailStore` 登記的最新一份），一定是使用者現在正看著的畫面。
        await detailStoreByAlbumID[albumID]?.store?.reflectUploadedMedia(mediaID)
    }

    /// 回傳這本相簿下一個要用的 `sortOrder`，同步（不 `await`）遞增本地快取——同一批次
    /// （`maxConcurrentUploads = 3`）內多張照片交錯完成時，只有第一張真的打一次
    /// `fetchMaxSortOrder`，後續照片直接從記憶體遞增，不會因為併發讀到同一個基底而撞號。
    ///
    /// **single-flight**：還沒快取基底時，第一個呼叫（`isOwner == true`）建立查詢 `Task`
    /// 存進 `.pending`，後續交錯呼叫（`isOwner == false`）共享同一個 `Task`（不會各自重複
    /// 打一次查詢）；`Task` 完成後多個呼叫的續行會排進同一個 `@MainActor` 依序執行（中間
    /// 沒有 `await`），只有第一個真正把狀態換成 `.ready` 並回傳查到的基底，其餘直接從已經是
    /// `.ready` 的狀態同步遞增——這裡沒有用額外的鎖，「同步遞增」本身就是靠 `@MainActor`
    /// 保證同一時間只有一個呼叫在跑這段不含 `await` 的程式碼達成原子性。
    ///
    /// **R2 修（merge-review R1 F2 minor）**：查詢失敗時，原本共用這個 `Task` 的**所有**
    /// 呼叫端都會收到同一個錯誤而放棄（`attachUploadedMedia` 的 `catch` 是靜默 best-effort
    /// ——一次暫時性網路失敗會讓同批最多 `maxConcurrentUploads` 張照片全部跳過
    /// `attachMedia`，media 列建好卻沒有連結）。改成只有真正發起查詢的那一次
    /// （`isOwner == true`）把失敗往外拋；加入同一個查詢的其他呼叫端（`isOwner == false`）
    /// 不連坐，狀態已經被清空，遞迴呼叫會各自建立新查詢獨立重試一次。
    private func nextSortOrder(forAlbum albumID: UUID) async throws -> Int {
        if case .ready(let next, let acquiredAt) = sortOrderCursors[albumID],
           now().timeIntervalSince(acquiredAt) < Self.sortOrderCursorIdleTTL {
            // LS-246 票文範圍 4：`acquiredAt` 原樣延續，不更新成 `now()`——見
            // `sortOrderCursorIdleTTL` 文件註解，TTL 從「查到基底值那一刻」算，不是「每次用
            // 到就延後」。
            sortOrderCursors[albumID] = .ready(next: next + 1, acquiredAt: acquiredAt)
            return next
        }
        let task: Task<Int?, Error>
        let isOwner: Bool
        // LS-246 票文範圍 3：`pendingID` 記下「自己這次是在等哪一個 `.pending`」——
        // `isOwner == true` 時是自己剛建立的那個新 id；`isOwner == false` 時是讀到既有
        // `.pending` 當下附帶的 id。下面 `catch` 清空前會核對這個 id 還在不在，見該處註解。
        let pendingID: UUID
        if case .pending(let existingID, let existing) = sortOrderCursors[albumID] {
            task = existing
            pendingID = existingID
            isOwner = false
        } else {
            let newID = UUID()
            let newTask = Task { try await self.apiClient.fetchMaxSortOrder(albumID: albumID) }
            sortOrderCursors[albumID] = .pending(id: newID, task: newTask)
            task = newTask
            pendingID = newID
            isOwner = true
        }
        do {
            let maxOrder = try await task.value
            let resolvedAt = now()
            if case .ready(let next, let acquiredAt) = sortOrderCursors[albumID],
               resolvedAt.timeIntervalSince(acquiredAt) < Self.sortOrderCursorIdleTTL {
                // 另一個交錯呼叫端已經搶先把狀態換成 `.ready`——沿用它的 `acquiredAt`（不是
                // `resolvedAt`），理由同上面文件註解。
                sortOrderCursors[albumID] = .ready(next: next + 1, acquiredAt: acquiredAt)
                return next
            }
            let next = (maxOrder ?? -1) + 1
            sortOrderCursors[albumID] = .ready(next: next + 1, acquiredAt: resolvedAt)
            return next
        } catch {
            // LS-246（票文範圍 3，池 `430a34a1` n1）：只有「現在字典裡的 `.pending` 仍然是
            // 自己剛才在等的那一筆」（`currentID == pendingID`）才清空——原本只看 case 是不是
            // `.pending`（不核對是哪一個 `Task`），晚到才處理失敗的等待者可能把「另一個交錯
            // 呼叫端剛建立、還在飛行中」的全新查詢誤清成 `nil`，代價是那個呼叫端的重試又白白
            // 多打一次查詢（無正確性影響，見 merge-review `5be48b1e` n1）。
            if case .pending(let currentID, _) = sortOrderCursors[albumID], currentID == pendingID {
                sortOrderCursors[albumID] = nil
            }
            guard isOwner else { return try await nextSortOrder(forAlbum: albumID) }
            throw error
        }
    }

    /// `AlbumDetailView.task(id:)` 建好 `AlbumDetailStore` 後呼叫——同一個 albumID 若已有舊
    /// 登記者（例如很快地前後兩次進入同一本相簿），直接覆蓋，只保留最新一份；`weak` 讓舊實例
    /// deinit 後自然從查找中消失，不需要另外處理「離開」事件。
    func subscribeDetailStore(albumID: UUID, _ store: AlbumDetailStore) {
        detailStoreByAlbumID[albumID] = WeakAlbumDetailStoreRef(store: store)
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
        // LS-237：下一個帳號的 sortOrder 基底跟這個帳號無關，登出時一併清掉快取。
        // R2 訂正（merge-review R1 i2）：`weak` 只讓 value（`AlbumDetailStore` 實例）在
        // deinit 後變 nil，字典本身的 key（進過的每一本 albumID）不會自動移除——`
        // detailStoreByAlbumID` 的 entry 數其實會隨本 session 瀏覽過的相簿數量增加，不是
        // 完全不會累積，只是這個量級（頂多幾十個 UUID key＋已經是 nil 的 box）可忽略不計；
        // 這裡清掉單純是避免登出後還殘留舊帳號的相簿 id 對照。
        sortOrderCursors = [:]
        detailStoreByAlbumID = [:]
        // LS-303 R5（merge-review R4 M1）：共用上傳佇列把 familyID 焊在第一次呼叫建立的
        // `UploadQueueStore` 裡（`AlbumsStore+SharedUploadQueue.swift` 檔頭文件註解）——
        // 不清掉這兩個屬性，登出換帳號後上傳仍會打舊家庭的 familyID。
        sharedUploadQueueStoreInstance = nil
        pendingUploadAlbumIDs = [:]
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
