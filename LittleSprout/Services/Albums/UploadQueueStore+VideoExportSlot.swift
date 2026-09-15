import Foundation

/// LS-286 i2／LS-288 i1：`UploadQueueStore` 的影片 export 專屬並行名額機制——拆成獨立檔案，
/// 理由同 `TimelineStore+Reactions.swift` 檔頭：主檔 `UploadQueueStore.swift` 逼近 SwiftLint
/// `file_length`（400 行）上限，這裡的方法會再加行數，才觸發拆檔。狀態本身
/// （`videoExportInFlight`／`videoExportWaiters`）仍宣告在主檔（Swift extension 不能加 stored
/// property），這裡只放操作它們的方法——因此那兩個屬性不能是 `private`（見主檔文件註解）。
extension UploadQueueStore {
    /// LS-286 i2：拿到名額就立刻標記並返回；沒有就排進等候佇列，等 `releaseVideoExportSlot()`
    /// 叫醒。呼叫端與 `releaseVideoExportSlot()` 都在 MainActor 上執行，不會有兩個呼叫同時看到
    /// `videoExportInFlight == false` 而都拿到名額的競態。
    ///
    /// **LS-288 i1**：`withTaskCancellationHandler` 讓排隊中的呼叫端在 Task 被取消時不用等到
    /// 真的拿到名額才發現——`onCancel` 不在 MainActor 上執行，用 `Task { @MainActor in }` 跳回
    /// 本 store 的隔離執行緒把這個等待者從 `videoExportWaiters` 移除並丟 `CancellationError`。
    /// 「resume 只能一次」靠陣列本身當單一事實來源：`cancelVideoExportWaiter(id:)` 與
    /// `releaseVideoExportSlot()` 都是先從陣列找到／移除這個等待者才 resume，同一個等待者只會
    /// 被其中一邊找到——找不到（代表已經被另一邊處理過）就直接 no-op，不會對同一個
    /// `CheckedContinuation` resume 兩次（兩者都在 MainActor 序列化執行，不會同時各自成功找到
    /// 同一筆）。
    func acquireVideoExportSlot() async throws {
        if !videoExportInFlight {
            videoExportInFlight = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                videoExportWaiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelVideoExportWaiter(id: waiterID)
            }
        }
    }

    /// 佇列裡還有人等就直接把名額轉給排最前面的那個（`videoExportInFlight` 維持 `true`，名額
    /// 沒有被釋放又重新搶過），沒人等才真的把名額放掉。
    func releaseVideoExportSlot() {
        if videoExportWaiters.isEmpty {
            videoExportInFlight = false
        } else {
            videoExportWaiters.removeFirst().continuation.resume()
        }
    }

    /// LS-288 i1：見 `acquireVideoExportSlot()` 文件註解——找不到就代表這個等待者已經被
    /// `releaseVideoExportSlot()` 正常 resume 過，不重複處理。
    private func cancelVideoExportWaiter(id: UUID) {
        guard let index = videoExportWaiters.firstIndex(where: { $0.id == id }) else { return }
        videoExportWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    #if DEBUG
    /// 測試用途（LS-288 i1）：直接驅動 `acquireVideoExportSlot()`／`releaseVideoExportSlot()`，
    /// 不經過完整 `enqueue`／`performUpload` 流程，讓測試能精準控制「哪一個等待者被取消」，
    /// 並用 `debugVideoExportWaiterCount` 觀察等候佇列長度是否真的移除了被取消的那一個。
    func debugAcquireVideoExportSlot() async throws {
        try await acquireVideoExportSlot()
    }

    func debugReleaseVideoExportSlot() {
        releaseVideoExportSlot()
    }

    var debugVideoExportWaiterCount: Int { videoExportWaiters.count }
    #endif
}
