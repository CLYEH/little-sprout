import AVFoundation
import Foundation
import Observation

/// `TimelineStore` 各非同步動作共用的狀態機，同 `ChildOperationState`／`FamilyStore.
/// FamilyOperationState` 的角色。
enum TimelineOperationState: Equatable {
    case idle
    case submitting
    case success
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 時間軸（LS-126）的 `@Observable` 狀態管理——把 `TimelineAPIClient` 包成畫面能直接讀狀態
/// 驅動重繪的 store（同 `ChildrenStore` 之於 `ChildAPIClient` 的角色）。
@MainActor
@Observable
final class TimelineStore {
    /// `get_family_timeline` 上界夾到 100、預設 20（docs/API.md）；這裡跟後端預設值一致，
    /// 不是隨意選的數字。
    static let pageSize = 20

    private let apiClient: TimelineAPIClient
    /// R2-M1（merge-review `b7ecfbf4`）：`loadVideoDuration` 讀時長的實際動作抽成可注入的
    /// 閉包，預設是真正的 `AVURLAsset(url:).load(.duration)`——只有這樣測試才能斷言「同一個
    /// mediaID 兩次呼叫只真正嘗試載入一次」（`failedDurations` 擋第二次），不必真的打網路
    /// 也不用等 AVFoundation 對一個必失敗的 URL 逾時。
    private let durationLoader: @Sendable (URL) async throws -> CMTime

    private(set) var entries: [TimelineEntry] = []
    private(set) var refreshState: TimelineOperationState = .idle
    private(set) var loadMoreState: TimelineOperationState = .idle
    private(set) var hasMorePages = true
    /// 影片時長（秒）——`media` 表沒有 `duration` 欄位，首次要顯示「影片 M:SS」徽章時才
    /// 向簽名 URL 指向的檔案讀 `AVURLAsset` 時長，讀過的結果快取在這裡，同一支影片不重複讀
    /// （見 `loadVideoDuration`）。
    private(set) var videoDurations: [UUID: TimeInterval] = [:]
    /// LS-216：愛心反應狀態，鍵＝`TimelineEntry.id(kind:refId:)`。每頁載入後批次補齊（見
    /// `loadReactionCounts`）；沒有反應的 target 不會出現在 `get_reaction_counts` 回傳裡，
    /// 缺席一律視為 `.zero`（見 `reactionState(forKey:)`），不需要顯式寫入。
    private(set) var reactionStates: [String: ReactionState] = [:]
    /// LS-216 票文 scope 2：`get_family_timeline`／`list_comments` 都沒有回留言計數欄位
    /// （已查 docs/API.md 確認，記入 handoff informational＋LS-96 池項）——這裡先恆為 0，
    /// 留一個 `setCommentCount` 寫入口給 LS-218（留言 sheet 讀到真正筆數後同步回這裡，
    /// 「計數同步來自互動列」，見 LS-218 票文依賴段）。
    private(set) var commentCounts: [String: Int] = [:]

    /// LS-216（改動）：原本是純 `private`（只給 `refreshWithCurrentFilter()` 內部沿用）——
    /// `InteractionRow` 需要目前的 `familyID` 才能呼叫 `toggleReaction`／`reactors`，改成
    /// `private(set)` 讓它能直接讀，不必往下多穿一層參數。
    private(set) var familyID: UUID?
    private var childID: UUID?
    private var loadingDurations: Set<UUID> = []
    /// LS-216：`toggleReaction` in-flight 去重（連點忽略，見該方法文件註解）。
    private var togglingReactionKeys: Set<String> = []
    /// R2-M1：讀取時長失敗過的 id——`loadVideoDuration` 原本失敗後什麼都不記，LS-130 讓
    /// 有縮圖的影片必定走進這條失敗路徑（`signedURL` 對它們是縮圖 JPEG，不是可解出時長的
    /// 影片檔），`.task(id:)` 隨卡片重建（例如捲出、捲回 `LazyVStack` 存活視窗）就會重跑，
    /// 沒有這個集合會讓請求數隨捲動次數線性成長——直接抵銷本票要爭取的 egress。呼叫端另外
    /// 用 `MediaContent.isThumbnail` 從源頭跳過縮圖列（見 `PhotoCardView`／
    /// `MasonryPhotoWallView`），這裡的集合是給其他真正失敗的情況（檔案格式看不懂、網路失敗
    /// 等既有情境）通用的硬化，兩者互補、不互斥。
    private var failedDurations: Set<UUID> = []
    /// 世代計數器（merge-review R1 M1／M2；R2-M1 修正）：每次 `refresh` 呼叫都遞增並記下
    /// 自己的世代號，await 回來要寫回 `entries`／`hasMorePages`／`refreshState`（或
    /// `loadMoreState`）前先確認世代號仍等於目前最新——不等於就代表這次呼叫已經被更新的
    /// 一次 `refresh` 取代，安靜丟棄結果，不寫回過期資料，也不誤把「被取代」寫成 `.failure`。
    ///
    /// 取代舊做法（`guard !refreshState.isSubmitting else { return false }`）：舊做法會讓
    /// 「换了 `childID` 的新呼叫」被還在飛的舊呼叫擋下、連參數（`self.childID`）都沒被記錄
    /// ——使用者切換 `ChildFilterBar` 時第一頁若還沒回來，新的篩選會整個不生效，畫面停在
    /// 舊篩選內容或空狀態，直到使用者再互動一次。
    ///
    /// **世代號單獨用在 `loadMore` 不夠**（merge-review R2-M1）：世代號只在 `refresh`
    /// **開始**時遞增，`refresh` **完成**時不會再動它。若 `loadMore` 是在一個 `refresh`
    /// 已經開始、但還沒完成的期間才起跑，兩者會拿到**同一個**世代號——`refresh` 完成後把
    /// `entries` 整批換掉，`loadMore` 稍後回來時世代號檢查依然通過（因為世代號沒有變），
    /// 就會把用「舊 `entries.last` 算出的游標」查到的頁 `append` 到已經被換成別的基底的
    /// `entries` 後面（跳項／混篩選／重複 id）。修法：`loadMore` 額外釘住自己出發當下
    /// `entries` 的尾端身分（`baseTailID`），寫回前**世代號與尾端身分都要吻合**才算數——
    /// 光世代號吻合不夠，因為它答不出「entries 有沒有在我等待期間被別的呼叫整批換掉」
    /// 這個問題，只有尾端身分能直接回答。
    private var generation = 0

    init(
        apiClient: TimelineAPIClient,
        durationLoader: @escaping @Sendable (URL) async throws -> CMTime = { url in
            try await AVURLAsset(url: url).load(.duration)
        }
    ) {
        self.apiClient = apiClient
        self.durationLoader = durationLoader
    }

    /// 第一頁／篩選條件改變時呼叫——整批換掉 `entries`。刻意**不**用 `isSubmitting` 擋重入
    /// （見上方 `generation` 文件註解）：多個呼叫可以同時在飛，`self.familyID`／
    /// `self.childID` 一律立即記錄，只有世代號最新的那一次的結果會被寫回
    /// `entries`／`hasMorePages`／`refreshState`。
    @discardableResult
    func refresh(familyID: UUID, childID: UUID?) async -> Bool {
        generation += 1
        let myGeneration = generation
        self.familyID = familyID
        self.childID = childID
        refreshState = .submitting
        do {
            let pointers = try await apiClient.fetchTimelinePointers(
                familyID: familyID, childID: childID, cursor: nil, limit: Self.pageSize
            )
            let newEntries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: apiClient)
            guard myGeneration == generation else { return false }
            entries = newEntries
            hasMorePages = pointers.count == Self.pageSize
            refreshState = .success
            // LS-216 R2（merge-review R1 M1）：計數載入**不**擋在 `refreshState = .success`
            // 之前——`refreshState` 代表「畫面內容本身」是否就緒，愛心是次要資訊，不該讓使用者
            // 多等一輪網路請求才看到時間軸；`@Observable` 賦值當下就通知觀察者，這裡 `await`
            // 只是延後這支 `async` 函式自己返回的時間點，不延後畫面更新，見 `loadReactionCounts`
            // 文件註解。
            await loadReactionCounts(for: newEntries, familyID: familyID, expectedGeneration: myGeneration)
            return true
        } catch {
            guard myGeneration == generation else { return false }
            guard !Task.isCancelled else {
                // 被更新的呼叫取代而取消（同一世代內罕見，通常世代號檢查已經先擋下），
                // 不是真的失敗——不落 `.failure` 誤導使用者，見上方 `generation` 文件註解。
                refreshState = .idle
                return false
            }
            refreshState = .failure(AppError.map(error))
            return false
        }
    }

    /// LS-189 R2（merge-review R1 B2）：封鎖／解除封鎖從別的畫面（`DiaryDetailView`／
    /// `BlockListView`）觸發的重抓——沿用上一次 `refresh(familyID:childID:)` 記下的篩選條件
    /// （`familyID`／`childID`，跟 `loadMore` 讀的是同一組私有屬性），呼叫端不需要知道
    /// `ChildFilterBar` 目前選了哪個孩子。`familyID` 為 nil（例如還沒 `refresh` 過）時是
    /// no-op（同 `loadMore` 對 `familyID` 缺失的既有處理）——`block_user`／`unblock_user` 生效
    /// 範圍是 `get_family_timeline`／留言／相簿三處查詢（`docs/API.md` §4），這裡只負責讓
    /// client 端已經拿到的快取跟上，不是後端要求的動作。
    @discardableResult
    func refreshWithCurrentFilter() async -> Bool {
        guard let familyID else { return false }
        return await refresh(familyID: familyID, childID: childID)
    }

    /// 捲到底載入下一頁——沿用 `refresh` 記下的 `familyID`／`childID`，游標取自目前最後一筆
    /// （`get_family_timeline` 回傳序＝`(occurred_at desc, ref_id desc)`，最後一筆就是最舊的
    /// 那一筆）。世代號與「出發當下的尾端身分」都在呼叫當下記錄（都不遞增，只有 `refresh`
    /// 遞增世代號）：寫回前兩者都要吻合目前現況，任一個對不上就代表 `entries` 已經被
    /// 別的呼叫換過基底，這批結果不再對應任何有效分頁位置，安靜作廢（見上方 `generation`
    /// 文件註解的 R2-M1 段——世代號單獨用不夠，見該處理由）。仍保留
    /// `!loadMoreState.isSubmitting` 擋同一世代內的重複呼叫（例如捲動觸發器意外重入兩次）
    /// ——這條跟 M1／R2-M1 是不同的情境，同參數重入本來就該擋。
    @discardableResult
    func loadMore() async -> Bool {
        guard !loadMoreState.isSubmitting, hasMorePages, let familyID, let last = entries.last else { return false }
        let myGeneration = generation
        let baseTailID = last.id
        loadMoreState = .submitting
        do {
            let cursor = TimelineCursor(occurredAt: last.occurredAt, refId: last.refId)
            let pointers = try await apiClient.fetchTimelinePointers(
                familyID: familyID, childID: childID, cursor: cursor, limit: Self.pageSize
            )
            let newEntries = try await TimelineContentAssembler.assemble(pointers: pointers, apiClient: apiClient)
            guard myGeneration == generation, entries.last?.id == baseTailID else {
                // entries 基底已經被更新的呼叫換掉——安靜丟棄，但要把 loadMoreState
                // 收回非 submitting，不然下一次使用者捲到底會被卡住的 in-flight guard
                // 永久擋住（見上方 `generation` 文件註解）。
                loadMoreState = .idle
                return false
            }
            entries.append(contentsOf: newEntries)
            hasMorePages = pointers.count == Self.pageSize
            loadMoreState = .success
            // LS-216 R2（merge-review R1 M1）：同 `refresh` 的既有理由——只補新追加這批的
            // 愛心計數（已經在 `entries` 裡的舊資料不重查），且不擋在 `loadMoreState = .success`
            // 之前，見 `loadReactionCounts` 文件註解。
            await loadReactionCounts(for: newEntries, familyID: familyID, expectedGeneration: myGeneration)
            return true
        } catch {
            guard myGeneration == generation, entries.last?.id == baseTailID else {
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

    /// 日記詳情開頁時呼叫——拿這篇日記**全部**附照（時間軸卡片只帶前 3 張預覽，見
    /// `TimelineContentAssembler.fetchDiaryPhotos` 文件註解）。
    func loadDiaryPhotos(diaryID: UUID) async throws -> [MediaContent] {
        try await TimelineContentAssembler.fetchDiaryPhotos(diaryID: diaryID, apiClient: apiClient)
    }

    /// 放大檢視／播放影片當下才呼叫——現簽一次全尺寸原檔 URL，不在列表／照片牆載入時
    /// 就簽（LS-130，docs/API.md §6「簽名 URL 與 egress 防線」：全尺寸只在放大檢視／
    /// 影片播放時才簽）。`storagePath` 來自呼叫端手上的 `MediaContent.storagePath`
    /// （`fetchDiaryPhotos` 已經帶著，不必重查 `media` 列）。簽名失敗（例如檔案剛好被
    /// 硬刪）時回傳 nil，呼叫端不播放（同既有「簽名失敗擋 tap」慣例，見
    /// `MasonryPhotoWallView.isPlayableVideo`）。
    func signFullSizeURL(storagePath: String) async throws -> URL? {
        let signed = try await apiClient.signedURLs(forStoragePaths: [storagePath])
        return signed[storagePath]
    }

    /// LS-190：刪除日記（`set_diary_deleted(p_deleted: true)`）成功後，呼叫端
    /// （`DiaryDetailView`）本地移除這篇，不等下一次 `refresh()` 才把它從時間軸拿掉——RPC
    /// 呼叫與陣列更新分開兩步，因為 `TimelineStore` 本身不持有 `DiaryAPIClient`（那支協定屬於
    /// 「建立／編輯日記」的職責邊界，見 `LittleSproutApp` 的 store 佈線），呼叫端自己呼叫 RPC
    /// 成功後再叫這支方法同步本地狀態。
    func removeDiaryEntryLocally(diaryID: UUID) {
        entries.removeAll { $0.kind == .diary && $0.refId == diaryID }
    }

    /// LS-216：`InteractionRow` 讀目前的愛心狀態——沒有紀錄（`get_reaction_counts` 沒有回、
    /// 或還沒載入過）一律視為 `.zero`，見 `reactionStates` 文件註解。
    func reactionState(forKey key: String) -> ReactionState {
        reactionStates[key] ?? .zero
    }

    /// LS-216：`InteractionRow` 讀目前的留言計數——見 `commentCounts` 文件註解（目前恆為 0，
    /// 待 LS-218 用 `setCommentCount` 同步真正筆數）。
    func commentCount(forKey key: String) -> Int {
        commentCounts[key] ?? 0
    }

    /// LS-218 之後：留言 sheet 讀到真正的留言筆數時呼叫，同步互動列顯示的計數（見
    /// `commentCounts` 文件註解「計數同步來自互動列」）。
    func setCommentCount(_ count: Int, forKey key: String) {
        commentCounts[key] = count
    }

    /// 切換單一 target 的愛心——樂觀更新＋失敗回滾＋連點去重（LS-216 票文 scope 2）。
    ///
    /// **連點去重**：`togglingReactionKeys` 的 `guard`／`insert` 在第一個 `await` 之前同步
    /// 完成——`@MainActor` 保證同一個 target key 的第二次呼叫不可能在第一次呼叫的 suspension
    /// point 之前插隊執行，第二次呼叫的 `guard` 會直接失敗、安靜忽略（不排隊、不報錯，票文
    /// 「in-flight 期間忽略」選項）。
    ///
    /// **樂觀更新**：本地先切換 `reactedByMe`＋±1 計數；RPC 回傳的 `reactedByMe` 是切換後的
    /// 權威值，用來校正本地猜測（正常情況下兩者一致，只有極罕見的跨裝置同時切換才會不一致，
    /// 這裡用伺服器的回答收斂 `reactedByMe`，不做進一步的計數重查——計數本身的些微誤差會在
    /// 下一次 `refresh`／`loadMore` 自然校正）。RPC 失敗時整個 `ReactionState` 回滾到呼叫前
    /// 的快照，並把 `AppError.map(error)` 往外拋，呼叫端（`InteractionRow`）決定怎麼顯示
    /// （既有 `.alert` 語彙，同 `DiaryDetailView.playVideo` 的既有寫法）。
    func toggleReaction(kind: FeedKind, refId: UUID, familyID: UUID) async throws {
        let key = TimelineEntry.id(kind: kind, refId: refId)
        guard !togglingReactionKeys.contains(key) else { return }
        togglingReactionKeys.insert(key)
        defer { togglingReactionKeys.remove(key) }
        let previous = reactionStates[key] ?? .zero
        let optimistic = previous.reactedByMe
            ? ReactionState(count: max(0, previous.count - 1), reactedByMe: false)
            : ReactionState(count: previous.count + 1, reactedByMe: true)
        reactionStates[key] = optimistic
        do {
            let reactedByMe = try await apiClient.toggleReaction(
                familyID: familyID, targetType: kind.rawValue, targetID: refId
            )
            reactionStates[key]?.reactedByMe = reactedByMe
        } catch {
            reactionStates[key] = previous
            throw AppError.map(error)
        }
    }

    /// 按讚名單 sheet 用——純轉發，不快取（票文：純資訊列表，開啟當下重查一次即可，見
    /// `LikersListSheet`）。
    func reactors(kind: FeedKind, refId: UUID, familyID: UUID) async throws -> [ReactorRow] {
        try await apiClient.reactors(familyID: familyID, targetType: kind.rawValue, targetID: refId)
    }

    /// LS-216 R2（merge-review R1 M1／M2）：一頁（或 `loadMore` 新追加的一段）內容組好之後，
    /// 依 `kind` 分組批次呼叫 `get_reaction_counts`——同一頁最多 3 次呼叫（一種 kind 一次，見
    /// `TimelineAPIClient.reactionCounts` 文件註解），三種 kind 用 `withTaskGroup` 平行發出
    /// （同 `TimelineContentAssembler.fetchContentMaps` 既有理由：序列 await 沒必要拉長總等待
    /// 時間），結果收集齊後**一次**寫回 `reactionStates`。
    ///
    /// **呼叫端 `await` 這支，但不擋使用者看到內容**：`@Observable` 屬性在賦值當下就通知觀察者
    /// （不必等外層 `async` 函式整個返回）——呼叫端（`refresh`／`loadMore`）已經在呼叫這支
    /// 之前就把 `entries`／`refreshState`／`loadMoreState` 寫成 `.success`，畫面此刻已經能顯示
    /// 時間軸本身；這支仍在跑的期間，愛心一律顯示 `reactionStates` 尚未覆寫前的預設 `.zero`。
    /// 寫回前重驗 `expectedGeneration == generation`：若飛行期間又有更新的 `refresh`（世代號
    /// 已前進），`entries` 已換過基底，這批結果安靜丟棄，不覆蓋新世代可能已更新的值。單一
    /// kind 查詢失敗（`try?`）不影響其餘 kind，缺席一律 `.zero`（下次會再試）。
    private func loadReactionCounts(for newEntries: [TimelineEntry], familyID: UUID, expectedGeneration: Int) async {
        let idsByKind = Dictionary(grouping: newEntries, by: \.kind).mapValues { $0.map(\.refId) }
        guard !idsByKind.isEmpty else { return }
        let apiClient = self.apiClient
        var merged: [String: ReactionState] = [:]
        await withTaskGroup(of: (FeedKind, [ReactionCountRow]).self) { group in
            for (kind, targetIDs) in idsByKind {
                group.addTask {
                    let rows = (try? await apiClient.reactionCounts(
                        familyID: familyID, targetType: kind.rawValue, targetIDs: targetIDs
                    )) ?? []
                    return (kind, rows)
                }
            }
            for await (kind, rows) in group {
                for row in rows {
                    merged[TimelineEntry.id(kind: kind, refId: row.targetID)] =
                        ReactionState(count: row.reactionCount, reactedByMe: row.reactedByMe)
                }
            }
        }
        guard expectedGeneration == generation else { return }
        // R3（merge-review R2 minor-1）：缺席一律 `.zero`——只寫 `merged` 有的 key 會讓掉到 0 筆的 target 卡住舊數字。
        for (kind, targetID) in idsByKind.flatMap({ kind, ids in ids.map { (kind, $0) } }) {
            let key = TimelineEntry.id(kind: kind, refId: targetID)
            reactionStates[key] = merged[key] ?? .zero
        }
    }

    /// 登出時歸零——同 `ChildrenStore.reset()`／`FamilyStore.reset()` 的角色（merge-review
    /// R1 M5：接上 `SettingsView.signOut()`，見該檔）。世代號一併遞增：任何還在飛、屬於
    /// 上一個帳號的 `refresh`／`loadMore` 呼叫回來時，世代號檢查會讓它們視為過期而作廢，
    /// 不會在登出後把上一個家庭的照片（簽名 URL 1 小時內仍可讀）寫回畫面。
    func reset() {
        entries = []
        refreshState = .idle
        loadMoreState = .idle
        hasMorePages = true
        videoDurations = [:]
        loadingDurations = []
        failedDurations = []
        reactionStates = [:]
        commentCounts = [:]
        togglingReactionKeys = []
        familyID = nil
        childID = nil
        generation += 1
    }

    #if DEBUG
    /// merge-review R2 M1 回歸測試用：`entries` 是 `private(set)`，只能從本檔（`TimelineStore`
    /// 的主宣告）寫入，同 `FamilyStore.seedMyFamilyForPreview` 的角色與理由（見該檔）——UI test
    /// 需要時間軸上有一張可點的日記卡才能真的 push 進 `DiaryDetailView`，`PreviewTimelineAPIClient`
    /// 的 `fetchTimelinePointers` 固定回傳 `[]`，無法靠正常 `refresh()` 流程餵資料。整支 `#if DEBUG`
    /// 圍住，同 `seedMyFamilyForPreview` 的圍欄理由，Release build 不會編到。
    ///
    /// LS-216：新增 `familyID` 參數（有預設值，既有呼叫端不受影響）——`InteractionRow` 呼叫
    /// `toggleReaction`／`reactors` 需要 `self.familyID` 非 nil，這條既有的 DEBUG-only 種子
    /// 路徑（`TapTargetGateHarness+Safety.swift`／`TimelineStoreDeleteDiaryTests` 既有呼叫端）
    /// 原本完全不碰 `familyID`，本票起若不補這個參數，任何用這條路徑種資料的互動列測試都會
    /// 因為 `familyID == nil` 而讓 `InteractionRow` 的按讚鈕靜默失效（`guard let familyID`
    /// 直接 return，見 `InteractionRow.toggleLike`）。
    @MainActor
    func seedForPreview(entries: [TimelineEntry], familyID: UUID = UUID()) {
        self.entries = entries
        self.familyID = familyID
        refreshState = .success
        hasMorePages = false
    }

    /// LS-216：`TapTargetGateHarness`／UITest／單元測試灌指定 target 的愛心狀態，不必真的
    /// 跑一次 `get_reaction_counts`——同 `seedForPreview(entries:)` 的角色與圍欄理由。
    @MainActor
    func seedReactionState(_ state: ReactionState, forKey key: String) {
        reactionStates[key] = state
    }
    #endif

    /// 讀一支影片的時長並快取；已經讀過、正在讀、或讀過且失敗的 id 直接跳過（避免同一支
    /// 影片的卡片多次觸發 `.task` 時重複打 Storage——R2-M1：失敗也要記，不是只記成功，見
    /// `failedDurations` 文件註解）。讀取失敗（例如檔案格式看不懂、網路失敗、縮圖 JPEG 本來
    /// 就解不出時長）時靜默放棄——呼叫端（`videoDurations[id]` 仍是 nil）退回只顯示「影片」
    /// 不帶秒數，不是整張卡片失敗。
    func loadVideoDuration(mediaID: UUID, url: URL) async {
        guard videoDurations[mediaID] == nil, !loadingDurations.contains(mediaID),
              !failedDurations.contains(mediaID) else { return }
        loadingDurations.insert(mediaID)
        defer { loadingDurations.remove(mediaID) }
        guard let duration = try? await durationLoader(url), duration.isValid, !duration.isIndefinite else {
            failedDurations.insert(mediaID)
            return
        }
        videoDurations[mediaID] = CMTimeGetSeconds(duration)
    }

    /// LS-135：徽章顯示用的時長，`PhotoCardView`／`DiaryCardView`／`MasonryPhotoWallView`
    /// 三個呼叫端共用同一份優先序判斷，不各自重寫——優先讀 `MediaContent.durationSeconds`
    /// （`media.duration_seconds` 查表值，LS-134／135 起上傳端直接量測寫入，不需要客戶端
    /// 解碼，`isThumbnail` 為 `true` 時也一樣有效）；`nil`（LS-135 之前上傳的舊列、或量測
    /// 失敗）才退回 `videoDurations`（`loadVideoDuration` 讀出來的快取，只有
    /// `needsVideoDurationLookup` 為 `true`、即 `signedURL` 是原檔時才有機會被填）。
    func displayDuration(for content: MediaContent) -> TimeInterval? {
        content.durationSeconds.map(TimeInterval.init) ?? videoDurations[content.id]
    }
}
