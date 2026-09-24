import Foundation

/// LS-319（LS-249 4/4）：批次匯入「指定寶貝」接線——`AlbumImportUploadCoordinator` 在每群
/// media 全部終局（上傳成功、不可重試失敗、或可重試失敗但暫時卡住，見下「M1」段）後，用該群
/// 成功上傳的 media 集合＋`babyIDs` 呼叫 `set_media_children_batch`（見 docs/API.md §4）。
///
/// **app 層級共用，不掛在 `ImportBatchSession`／畫面上**：同 `UploadQueueStore`／
/// `AlbumsStore.pendingUploadAlbumIDs` 既有理由（見 `AlbumsStore+SharedUploadQueue.swift`
/// 檔頭 M2）——使用者「在背景繼續」離開 04／05，`ImportBatchSession` 隨畫面消失，但佇列裡
/// 還在飛行中的上傳、與這裡追蹤的「這群還差幾筆」都要撐到真正結束，不能依賴任何 view-scoped
/// 物件存活。掛在 `AlbumsStore.mediaChildrenMarker`，跟 `sharedUploadQueueStore` 一樣是 app
/// 層級全程存活。
///
/// **判定點**：`AlbumImportUploadCoordinator.enqueue(group:...)` 對每個非空 `babyIDs` 的群，
/// 在開始讀取這一群的 identifier 前呼叫 `beginGroup`；每產生一筆 `PendingUpload`（一個
/// identifier 可能展開成 0～2 筆，見該檔文件註解）、在 `store.enqueue([upload])` **之前**
/// 呼叫 `registerEntry`（同 `AlbumsStore.registerPendingAlbum` 既有慣例：登記必須先於入列，
/// 否則上傳比登記更快完成時查表會落空）；群的 identifier 迴圈結束後（不論中途是否被 04b
/// 取消）呼叫 `finishRegisteringGroup`。「這一群是否已經全部終局」用「已註冊筆數」與「已解決
/// 筆數」兩個計數器比對，不是等 identifier 讀取迴圈跑完就假設群已完成——Live Photo 展開／
/// 逐筆非同步讀取讓「這一群總共會有幾筆」要等迴圈真的跑完才知道，跟 `ImportBatchSession
/// .isFullyEnqueued` 同一套理由（見該型別文件註解）。
///
/// **M1（merge-review R1）：可重試失敗不得永久擋住同群其餘已成功項目的標記**。
/// `UploadQueueStore.finish(_:state:)` 對可重試失敗（`.network`／`.server`）**不會**呼叫
/// `onUploadFailedTerminal`（`payload` 還留著給 `retry(_:)` 用）——R1 版本只掛
/// `onUploadFailedTerminal`，於是群裡只要有一筆卡在可重試失敗、使用者又沒有剛好重試成功，
/// `resolvedCount` 就永遠追不上 `registeredCount`，整群（含已經上傳成功的那幾張）永遠不會
/// 標記，05 摘要也不會顯示任何異狀。R2 修法：`UploadQueueStore` 新增 additive 掛鉤
/// `onUploadFailedRetryable`（見該屬性文件註解，不影響既有呼叫端），接到 `AlbumsStore
/// +SharedUploadQueue.swift`→`handleUploadFailedRetryable(entryID:)`——可重試失敗第一次發生時
/// 就把這筆算進 `resolvedCount`（「這一群不會再等它了」），讓群在「其餘項目都終局」的當下就能
/// 結算並送出成功子集，不必等這筆真的重試成功或使用者放棄。`entryToGroup` 對這筆**不會**被
/// 移除（跟終局失敗不同）——若使用者之後按「重試失敗項」且這次成功，`handleUploadSucceeded`
/// 認得出這是「補交」的一筆，補送一次只含這一筆 media 的標記 RPC（獨立呼叫，`set_media_children
/// _batch` 全覆蓋語意下與其他批次呼叫互不影響、重送也無害）。若使用者不重試，這筆的登記
/// （`pendingRetryableEntries`／`entryToGroup`）留在記憶體直到登出 `reset()`——與既有
/// `failedGroups` 同一個量級（merge-review R1 i1／R2 派工單裁決記入 LS-96 待辦池，不在本票
/// 額外處理）。
///
/// **04b 取消整批**：`UploadQueueStore.cancelPendingImportItems` 對每一筆（含 `.uploading`
/// 中）都呼叫 `onUploadFailedTerminal`（見該方法文件註解）——`handleUploadFailedTerminal` 對
/// 「已經在 `pendingRetryableEntries` 裡」的筆只做收尾清理（不重複計數，見該方法實作），對
/// 「還沒失敗過」的筆走既有終局路徑；兩種情況群都會在其餘筆數到齊時正確結算，不需要另外處理
/// 取消。
///
/// **原子性交給後端**：這裡只負責「湊齊一群、發一次（或分批）RPC」，`set_media_children_batch`
/// 本身「全成功或全失敗」（見 docs/API.md §4）——群內任何一筆標記失敗，整群都算「標記未完成」，
/// 不細分哪幾筆成功哪幾筆沒有（沿後端契約，不在 client 端重新發明部分成功語意）；「重試標記」
/// 原樣重送整群（全覆蓋語意下重覆送已成功的部分是無害的 no-op）。
///
/// **m2（merge-review R1）：`LS044`（寶貝已軟刪）不提供「重試標記」**——payload 原樣重送
/// 永遠不會成功（沒有任何入口能改 `babyIDs`），跟上傳側 `.quota` 被判定不可重試的理由一致
/// （`UploadFailureReason.isRetryable`）。`failedMarkingMediaCount(in:)` 仍計入（照片確實沒有
/// 標記，這是事實），但 `retryableFailedMarkingCount(in:)`／`retryFailedMarking(in:)` 排除它，
/// 05 摘要「重試標記」鈕只在還有可重試的失敗群時才顯示（沿既有「重試失敗項排除 LS002」的 tier
/// 慣例）。
///
/// **≤500 筆分批**：`set_media_children_batch` 契約上限 500 筆／次（見 docs/API.md §4）——單一
/// 匯入群的成功筆數理論上可能超過（Live Photo 把每個 asset 展開成兩筆，票文匯入上限 200 張
/// 時最多 400 筆，目前不會真的觸發，這裡仍照契約分批，不假設呼叫端不會超過）；任一批失敗就
/// 整群記為「標記未完成」，不追蹤「這群裡哪一批已經成功」。
@MainActor
@Observable
final class MediaChildrenMarkingTracker {
    /// 呼叫端（`AlbumImportUploadCoordinator`）在開始處理一群之前自己產生、貫穿這一群整個
    /// 生命週期的識別碼——刻意不用 `ImportPlan.Group.id`（`String`，同一個字串在不同批次
    /// 之間可能重複，例如兩次先後的匯入都各自有一個「日期不明」群，見該型別文件註解），app
    /// 層級共用的追蹤器必須保證跨批次也不會撞碼。
    struct GroupKey: Hashable {
        private let value = UUID()
        init() {}
    }

    private struct GroupState {
        let babyIDs: [UUID]
        var entryIDs: Set<UUID> = []
        var succeededMediaIDs: [UUID] = []
        var registeredCount = 0
        /// 成功、不可重試失敗、或可重試失敗（見檔頭「M1」段）皆計入——代表「不會再等這一筆」，
        /// 不代表這一筆真的有結果可以標記。
        var resolvedCount = 0
        var isFullyRegistered = false
    }

    /// 標記失敗、（可能）可重試的群——保留湊齊當下的成功 media 集合＋babyIDs，「重試標記」
    /// 對可重試的群原樣重送，不重新等上傳（上傳早就終局了）。
    private struct FailedGroup {
        let entryIDs: Set<UUID>
        let mediaIDs: [UUID]
        let babyIDs: [UUID]
        /// m2（merge-review R1）：`LS044` 等「重送也不會變」的錯誤不可重試，見檔頭文件註解。
        let isRetryable: Bool
    }

    /// 單次 RPC 上限（見 docs/API.md §4 `set_media_children_batch` 500 筆上限）。
    static let batchLimit = 500

    private let apiClient: AlbumsAPIClient
    /// 標記成功後通知呼叫端補一次時間軸刷新——沿用 LS-328 既有入口
    /// （`TimelineStore.handleImportBatchMediaUploaded()`），不另造機制：標記 RPC 在上傳成功
    /// 之後才發生，LS-328 那次去抖刷新拿到的快照可能還沒有這一輪的 `child_ids`，這裡標記
    /// 完成後再補一次同一個入口，讓 `p_child_id` 篩選看得到剛標記好的照片。
    ///
    /// `var`（不是 `let`）：唯一呼叫端 `AlbumsStore.init` 需要捕捉 `self.timelineStore`，只能
    /// 在 `self` 完全初始化之後才賦值（見該檔文件註解），這裡先接受一個空閉包、稍後由
    /// `AlbumsStore.init` 補上，不是給呼叫端隨時重新指定用的。
    var onMarked: () -> Void

    private var entryToGroup: [UUID: GroupKey] = [:]
    private var groups: [GroupKey: GroupState] = [:]
    /// M1 修法（merge-review R1）：entryID → 這筆所屬群的 `babyIDs`——只在「這筆可重試失敗、
    /// 已經算進 `resolvedCount`、但還沒有真正的結果」時存在。`handleUploadSucceeded` 用它判斷
    /// 「這是不是一筆補交」；`handleUploadFailedTerminal` 用它判斷「這筆的計數帳本來就已經記過
    /// 了，這次只是清理，不要再記一次」。
    private var pendingRetryableEntries: [UUID: [UUID]] = [:]
    /// 只透過 `failedMarkingMediaCount(in:)`／`retryableFailedMarkingCount(in:)`／
    /// `retryFailedMarking(in:)` 對外讀寫（見下）——不直接對外開放整份字典，呼叫端不需要知道
    /// `FailedGroup` 這個內部型別。
    private var failedGroups: [GroupKey: FailedGroup] = [:]
    /// LS-373 D5：「補上寶貝」已送出、RPC 還沒回來的群——期間 `failedGroups` 仍保留該群（05 的
    /// 統計子列與 Marking Section 版面不動，Notes `x73Dy6`），按鈕靠 `isRetryingMarking(in:)`
    /// 切停用態；`mark` 寫回結果的同一段同步程式碼裡移除，成功時列與停用態一起消失。
    private var inFlightRetryKeys: Set<GroupKey> = []

    init(apiClient: AlbumsAPIClient, onMarked: @escaping () -> Void) {
        self.apiClient = apiClient
        self.onMarked = onMarked
    }

    // MARK: - 註冊（`AlbumImportUploadCoordinator` 呼叫，見檔頭「判定點」）

    /// 只在群的 `babyIDs` 非空時呼叫——空群完全不進追蹤器，見票文範圍 1「babyIDs 為空的群
    /// 不呼叫」，`registerEntry`／`finishRegisteringGroup` 對沒有先呼叫過這支的 `key` 皆為
    /// no-op（見下）。
    func beginGroup(_ key: GroupKey, babyIDs: [UUID]) {
        guard !babyIDs.isEmpty else { return }
        groups[key] = GroupState(babyIDs: babyIDs)
    }

    /// 必須在 `store.enqueue([upload])` **之前**呼叫（見檔頭文件註解「判定點」）。
    func registerEntry(_ key: GroupKey, entryID: UUID) {
        guard groups[key] != nil else { return }
        groups[key]?.entryIDs.insert(entryID)
        groups[key]?.registeredCount += 1
        entryToGroup[entryID] = key
    }

    /// 這一群的 identifier 迴圈跑完（不論中途是否被 04b 取消）——見檔頭文件註解「判定點」。
    func finishRegisteringGroup(_ key: GroupKey) {
        guard groups[key] != nil else { return }
        groups[key]?.isFullyRegistered = true
        finalizeIfReady(key)
    }

    // MARK: - 上傳結果回報（`AlbumsStore+SharedUploadQueue.swift` 的 `onUploadSucceeded`／
    // `onUploadFailedTerminal`／`onUploadFailedRetryable` 掛鉤呼叫）

    func handleUploadSucceeded(entryID: UUID, mediaID: UUID) {
        // M1：這筆先前卡在可重試失敗、已經算進所屬群的 `resolvedCount`（那個群可能早就已經
        // 結算並送出標記了）——這次成功是「補交」，獨立補送一次只含這一筆的標記，不回頭動
        // 原本的群（原本的群不再持有這筆的 media id，也不應該再持有：避免重複標記或狀態不一致）。
        if let babyIDs = pendingRetryableEntries.removeValue(forKey: entryID) {
            entryToGroup.removeValue(forKey: entryID)
            let key = GroupKey()
            Task { await self.mark(key: key, entryIDs: [entryID], mediaIDs: [mediaID], babyIDs: babyIDs) }
            return
        }
        guard let key = entryToGroup.removeValue(forKey: entryID) else { return }
        groups[key]?.succeededMediaIDs.append(mediaID)
        groups[key]?.resolvedCount += 1
        finalizeIfReady(key)
    }

    func handleUploadFailedTerminal(entryID: UUID) {
        // M1：這筆先前已經因為可重試失敗被算進 `resolvedCount` 過一次——這次终局失敗（重試後
        // 换了一個不可重試的原因，或 04b 取消時直接判定終局）不用再記一次，只需要清掉殘留登記。
        if pendingRetryableEntries.removeValue(forKey: entryID) != nil {
            entryToGroup.removeValue(forKey: entryID)
            return
        }
        guard let key = entryToGroup.removeValue(forKey: entryID) else { return }
        groups[key]?.resolvedCount += 1
        finalizeIfReady(key)
    }

    /// M1：可重試失敗——不移除 `entryToGroup`（可能之後補交，見 `handleUploadSucceeded`），
    /// 但算進 `resolvedCount`（「不會再等這一筆」），讓群能在其餘項目都終局後正確結算成功子集。
    /// 同一筆可能重複觸發（重試又失敗），`pendingRetryableEntries[entryID] == nil` 守門確保
    /// 只在第一次發生時記帳，之後的重複事件是 no-op（不然重試兩次失敗會把同一筆記成解決了
    /// 兩次）。
    func handleUploadFailedRetryable(entryID: UUID) {
        guard let key = entryToGroup[entryID], pendingRetryableEntries[entryID] == nil,
              let babyIDs = groups[key]?.babyIDs
        else { return }
        pendingRetryableEntries[entryID] = babyIDs
        groups[key]?.resolvedCount += 1
        finalizeIfReady(key)
    }

    private func finalizeIfReady(_ key: GroupKey) {
        guard let state = groups[key], state.isFullyRegistered, state.resolvedCount >= state.registeredCount else {
            return
        }
        groups.removeValue(forKey: key)
        guard !state.succeededMediaIDs.isEmpty else { return }
        let entryIDs = state.entryIDs
        let mediaIDs = state.succeededMediaIDs
        let babyIDs = state.babyIDs
        Task { await self.mark(key: key, entryIDs: entryIDs, mediaIDs: mediaIDs, babyIDs: babyIDs) }
    }

    // MARK: - 標記（RPC）

    private func mark(key: GroupKey, entryIDs: Set<UUID>, mediaIDs: [UUID], babyIDs: [UUID]) async {
        do {
            for chunk in Self.chunked(mediaIDs, size: Self.batchLimit) {
                let items = chunk.map { MediaChildrenBatchItem(mediaID: $0, childIDs: babyIDs) }
                try await apiClient.setMediaChildrenBatch(items: items)
            }
            failedGroups.removeValue(forKey: key)
            inFlightRetryKeys.remove(key)
            onMarked()
        } catch {
            let isRetryable = Self.isMarkingErrorRetryable(error)
            failedGroups[key] = FailedGroup(
                entryIDs: entryIDs, mediaIDs: mediaIDs, babyIDs: babyIDs, isRetryable: isRetryable
            )
            inFlightRetryKeys.remove(key)
        }
    }

    /// m2（merge-review R1）：`LS044`（寶貝已軟刪）原樣重送永遠不會成功——同一次呼叫不會因為
    /// 時間經過而變出結果，跟上傳側 `.quota` 被判定不可重試的理由一致。其餘碼
    /// （`42501`／`23503`／`22023`）都屬於稍後再試或環境修正後可能成功的分類。
    private static func isMarkingErrorRetryable(_ error: Error) -> Bool {
        guard let appError = error as? AppError, case .validationRetryable(_, let code) = appError,
              code == LSErrorCode.childDeletedCannotAttachContent.rawValue
        else { return true }
        return false
    }

    private static func chunked(_ items: [UUID], size: Int) -> [[UUID]] {
        guard size > 0, items.count > size else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<Swift.min($0 + size, items.count)]) }
    }

    // MARK: - 05 摘要頁讀取／重試

    /// 「N 張寶貝標記未完成」的 N——只算跟這個批次（`session.entryIDSet`）有交集的失敗群，
    /// 不分是否可重試（照片確實沒有標記，這是事實，見 m2 文件註解）。
    func failedMarkingMediaCount(in entryIDs: Set<UUID>) -> Int {
        failedGroups.values
            .filter { !$0.entryIDs.isDisjoint(with: entryIDs) }
            .reduce(0) { $0 + $1.mediaIDs.count }
    }

    /// 「重試標記（N）」鈕的 N 與可視性用——只算可重試的失敗群（m2：`LS044` 排除，沿 05 既有
    /// 「重試失敗項排除 LS002」的 tier 慣例）。
    func retryableFailedMarkingCount(in entryIDs: Set<UUID>) -> Int {
        failedGroups.values
            .filter { $0.isRetryable && !$0.entryIDs.isDisjoint(with: entryIDs) }
            .reduce(0) { $0 + $1.mediaIDs.count }
    }

    /// 「補上寶貝」——只重送跟這個批次有交集、且可重試的失敗群，不動其他批次、不重新上傳
    /// （上傳早就終局了，見檔頭文件註解）。LS-373 D5：送出時不從 `failedGroups` 移除（R1 版本
    /// 按下即移除，列瞬間消失、失敗再出現），改記進 `inFlightRetryKeys`，結果回來才一起更新；
    /// 已在進行中的群不重送（連點／重入）。
    func retryFailedMarking(in entryIDs: Set<UUID>) {
        let keysToRetry = failedGroups.keys.filter { key in
            guard !inFlightRetryKeys.contains(key), let group = failedGroups[key], group.isRetryable else {
                return false
            }
            return !group.entryIDs.isDisjoint(with: entryIDs)
        }
        for key in keysToRetry {
            guard let group = failedGroups[key] else { continue }
            inFlightRetryKeys.insert(key)
            Task {
                await self.mark(key: key, entryIDs: group.entryIDs, mediaIDs: group.mediaIDs, babyIDs: group.babyIDs)
            }
        }
    }

    /// LS-373 D5：這個批次有沒有「補上寶貝」請求還在進行中——05 按鈕停用＋「正在補上寶貝…」。
    func isRetryingMarking(in entryIDs: Set<UUID>) -> Bool {
        inFlightRetryKeys.contains { key in
            failedGroups[key].map { !$0.entryIDs.isDisjoint(with: entryIDs) } ?? false
        }
    }

    /// 登出時歸零（同 `AlbumsStore.reset()` 既有慣例）。
    func reset() {
        entryToGroup = [:]
        groups = [:]
        pendingRetryableEntries = [:]
        failedGroups = [:]
        inFlightRetryKeys = []
    }
}

/// `#Preview`／`TapTargetGateHarness`／UITest 用的灌狀態工具——直接灌一個「標記失敗」的群，
/// 不經過真正的 RPC 呼叫（同 `UploadQueueStore+Preview.swift` 的角色與圍欄理由）。跟主類別
/// 同一個檔案（不是另開檔）：要直接寫入 `failedGroups`／`FailedGroup`（`private`，Swift 的
/// `private` 以檔案為界），同 `UploadQueueStore+Preview.swift` 對 `entries` 的存取模式。
#if DEBUG
extension MediaChildrenMarkingTracker {
    /// `entryIDs` 用呼叫端真正的批次 `session.entryIDSet` 子集，讓
    /// `failedMarkingMediaCount(in:)` 對得上——05 摘要頁是靠這個交集判斷要不要顯示那一行；
    /// `mediaIDs` 不需要對應真的上傳過的媒體，只是拿來湊「N 張」這個數字。`isRetryable`
    /// 預設 `true`（一般失敗態）；截 `LS044` 那種不可重試態的畫面另傳 `false`。
    func seedFailedMarkingForPreview(
        entryIDs: [UUID], mediaIDs: [UUID], babyIDs: [UUID] = [UUID()], isRetryable: Bool = true
    ) {
        let key = GroupKey()
        failedGroups[key] = FailedGroup(
            entryIDs: Set(entryIDs), mediaIDs: mediaIDs, babyIDs: babyIDs, isRetryable: isRetryable
        )
    }
}
#endif
