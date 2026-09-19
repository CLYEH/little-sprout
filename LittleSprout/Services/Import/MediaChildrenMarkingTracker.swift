import Foundation

/// LS-319（LS-249 4/4）：批次匯入「指定寶貝」接線——`AlbumImportUploadCoordinator` 在每群
/// media 全部終局（上傳成功或不可重試失敗）後，用該群成功上傳的 media 集合＋`babyIDs` 呼叫
/// `set_media_children_batch`（見 docs/API.md §4）。
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
/// 取消）呼叫 `finishRegisteringGroup`。「這一群是否已經全部終局」用「已註冊筆數」與「已終局
/// 筆數」兩個計數器比對，不是等 identifier 讀取迴圈跑完就假設群已完成——Live Photo 展開／
/// 逐筆非同步讀取讓「這一群總共會有幾筆」要等迴圈真的跑完才知道，跟 `ImportBatchSession
/// .isFullyEnqueued` 同一套理由（見該型別文件註解）；`AlbumsStore+SharedUploadQueue.swift`
/// 的 `onUploadSucceeded`／`onUploadFailedTerminal` 掛鉤呼叫 `handleUploadSucceeded`／
/// `handleUploadFailedTerminal`——跟 `pendingUploadAlbumIDs` 共用同一組事件來源，天然序列化
/// 在 MainActor 上，不會有兩筆同時修改同一個群狀態的競態。04b「取消整批」透過
/// `UploadQueueStore.cancelPendingImportItems` 對每一筆（含 `.uploading` 中）都呼叫
/// `onUploadFailedTerminal`（見該方法文件註解）——這裡因此不需要另外處理取消，取消的筆會被
/// 當成終局失敗算進「已終局」，群一樣會在其餘筆數到齊時正確結算（只標記真的成功的那些）。
///
/// **原子性交給後端**：這裡只負責「湊齊一群、發一次（或分批）RPC」，`set_media_children_batch`
/// 本身「全成功或全失敗」（見 docs/API.md §4）——群內任何一筆標記失敗，整群都算「標記未完成」，
/// 不細分哪幾筆成功哪幾筆沒有（沿後端契約，不在 client 端重新發明部分成功語意）；「重試標記」
/// 原樣重送整群（全覆蓋語意下重覆送已成功的部分是無害的 no-op）。
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
        var resolvedCount = 0
        var isFullyRegistered = false
    }

    /// 標記失敗、可重試的群——保留湊齊當下的成功 media 集合＋babyIDs，「重試標記」原樣重送，
    /// 不重新等上傳（上傳早就終局了）。
    private struct FailedGroup {
        let entryIDs: Set<UUID>
        let mediaIDs: [UUID]
        let babyIDs: [UUID]
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
    /// 只透過 `failedMarkingMediaCount(in:)`／`retryFailedMarking(in:)` 對外讀寫（見下）——
    /// 不直接對外開放整份字典，呼叫端不需要知道 `FailedGroup` 這個內部型別。
    private var failedGroups: [GroupKey: FailedGroup] = [:]

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
    // `onUploadFailedTerminal` 掛鉤呼叫）

    func handleUploadSucceeded(entryID: UUID, mediaID: UUID) {
        guard let key = entryToGroup.removeValue(forKey: entryID) else { return }
        groups[key]?.succeededMediaIDs.append(mediaID)
        groups[key]?.resolvedCount += 1
        finalizeIfReady(key)
    }

    func handleUploadFailedTerminal(entryID: UUID) {
        guard let key = entryToGroup.removeValue(forKey: entryID) else { return }
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
            onMarked()
        } catch {
            failedGroups[key] = FailedGroup(entryIDs: entryIDs, mediaIDs: mediaIDs, babyIDs: babyIDs)
        }
    }

    private static func chunked(_ items: [UUID], size: Int) -> [[UUID]] {
        guard size > 0, items.count > size else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<Swift.min($0 + size, items.count)]) }
    }

    // MARK: - 05 摘要頁讀取／重試

    /// 「N 張寶貝標記未完成」的 N——只算跟這個批次（`session.entryIDSet`）有交集的失敗群。
    func failedMarkingMediaCount(in entryIDs: Set<UUID>) -> Int {
        failedGroups.values
            .filter { !$0.entryIDs.isDisjoint(with: entryIDs) }
            .reduce(0) { $0 + $1.mediaIDs.count }
    }

    /// 「重試標記」——只重送跟這個批次有交集的失敗群，不動其他批次、不重新上傳（上傳早就
    /// 終局了，見檔頭文件註解）。
    func retryFailedMarking(in entryIDs: Set<UUID>) {
        let keysToRetry = failedGroups.keys.filter { key in
            guard let group = failedGroups[key] else { return false }
            return !group.entryIDs.isDisjoint(with: entryIDs)
        }
        for key in keysToRetry {
            guard let group = failedGroups.removeValue(forKey: key) else { continue }
            Task {
                await self.mark(key: key, entryIDs: group.entryIDs, mediaIDs: group.mediaIDs, babyIDs: group.babyIDs)
            }
        }
    }

    /// 登出時歸零（同 `AlbumsStore.reset()` 既有慣例）。
    func reset() {
        entryToGroup = [:]
        groups = [:]
        failedGroups = [:]
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
    /// `mediaIDs` 不需要對應真的上傳過的媒體，只是拿來湊「N 張」這個數字。
    func seedFailedMarkingForPreview(entryIDs: [UUID], mediaIDs: [UUID], babyIDs: [UUID] = [UUID()]) {
        let key = GroupKey()
        failedGroups[key] = FailedGroup(entryIDs: Set(entryIDs), mediaIDs: mediaIDs, babyIDs: babyIDs)
    }
}
#endif
