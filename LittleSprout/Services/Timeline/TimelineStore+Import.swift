import Foundation

/// LS-328（源自 LS-315 R3 `957707ef` 風險 1）：批次匯入（時間軸入口／相簿詳情入口皆同一份
/// 共用上傳佇列，見 `AlbumsStore+SharedUploadQueue.swift`）上傳成功後，`AlbumsStore
/// .sharedUploadQueueStore` 的 `onUploadSucceeded` 掛鉤會呼叫 `handleImportBatchMediaUploaded()`
/// ——不論那筆媒體有沒有掛進相簿（跟 `attachUploadedMedia` 只在有登記 albumID 才動作的職責
/// 邊界不同，時間軸顯示所有未軟刪 media，不限有沒有相簿連結）。
///
/// **去抖**：同一批次密集完成的多張照片只想觸發一次 refresh，不是每張都打一次
/// `get_family_timeline`——每次呼叫都佔用一個新 `debounceToken`，等待 `debounceDelay()`
/// （可注入，測試用 `AsyncGate` 精準控制，不猜真實時間，同 `durationLoader` 既有可注入掛鉤
/// 慣例）之後只有仍是最新 token 的那次才真的動作；等待期間又有新的一張完成，token 被佔用，
/// 這次呼叫安靜作廢（下一個新 token 的呼叫會負責）——寫法同 `TimelineStore.generation` 既有
/// token 比對慣例。
///
/// **不在畫面上**：標記 `isDirty`，`screenDidAppear()`（`TimelineView.onAppear`）發現後補一次
/// refresh 並清旗標；**在畫面上**：直接呼叫 `refresh(familyID:childID:)`——刻意**不** force，
/// 沿用 LS-266 既有 in-flight 合流（跟使用者同時下拉刷新只會真的打一次請求，不重複發送）。
struct TimelineImportRefreshState {
    var isOnScreen = false
    var isDirty = false
    var debounceToken = 0
    var debounceDelay: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 800_000_000) }
}

extension TimelineStore {
    /// 見檔頭文件註解「去抖」段。回傳值供測試 `await` 到這次去抖動作真正結束（成功呼叫
    /// `refresh` 或安靜作廢），不是給正式呼叫端使用（fire-and-forget）。
    @discardableResult
    func handleImportBatchMediaUploaded() -> Task<Void, Never> {
        importRefresh.debounceToken += 1
        let myToken = importRefresh.debounceToken
        // i2（merge-review R1，informational）：故意不用 `[weak self]`——`TimelineStore` 是
        // app 層級全程存活，這個 Task 不會造成循環參照，頂多讓它在登出瞬間多活
        // `debounceDelay()` 那麼久；目前沒有呼叫端會取消這個 Task，不處理。
        return Task {
            await importRefresh.debounceDelay()
            // i1（merge-review R1）：familyID 為 nil 時這裡不標記 isDirty——初次登入還沒
            // refresh 過，`TimelineView.task(id:)` 本來就會在 familyID 到位後自動做第一次
            // 載入，不需要靠這裡的 dirty 機制補；真正要在意的是「已經 refresh 過、只是 token
            // 過期」那一種情形，不是這裡。
            guard myToken == importRefresh.debounceToken, let familyID else { return }
            if importRefresh.isOnScreen {
                // M1（merge-review R1）：`refresh` 不 force，可能合流進「發起於這張照片落地
                // 之前」的舊一輪（LS-266 R2 B1 的世代比對只擋「已被淘汰的世代」，擋不下「同
                // 世代、但發起時間早於這次伺服器端狀態改變」——同 `refreshWithCurrentFilter()`
                // 文件註解 LS-266 R2 i1 那句話）。合流時 `generation` 不會遞增（見 `refresh`
                // 內 `!force` 分支），藉此分辨「這次呼叫是不是真的發起了新一輪」：若沒有
                // （代表拿到的是舊快照，可能不含最後一張），且沒有更新的通知進來
                // （`myToken` 仍是最新），就再補一次 `force: true`，保證使用者最終看到伺服器
                // 當下的真實狀態，不必等下一次手動下拉。
                let generationBefore = generation
                await refresh(familyID: familyID, childID: childID)
                if generation == generationBefore, myToken == importRefresh.debounceToken {
                    await refresh(familyID: familyID, childID: childID, force: true)
                }
            } else {
                importRefresh.isDirty = true
            }
        }
    }

    /// `TimelineView.onAppear` 呼叫——見檔頭文件註解「不在畫面上」段。回傳值同上，供測試用。
    @discardableResult
    func screenDidAppear() -> Task<Void, Never>? {
        importRefresh.isOnScreen = true
        guard importRefresh.isDirty, let familyID else { return nil }
        importRefresh.isDirty = false
        return Task { await refresh(familyID: familyID, childID: childID) }
    }

    /// `TimelineView.onDisappear` 呼叫。
    func screenDidDisappear() {
        importRefresh.isOnScreen = false
    }
}
