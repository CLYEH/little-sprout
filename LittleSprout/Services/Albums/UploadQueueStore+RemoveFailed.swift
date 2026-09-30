import Foundation

/// LS-410（LS-403 iOS 段，`design/littlesprout.pen` Notes `FBoLL`）：上傳佇列 sheet 的「移除失敗項」。
///
/// **兩段式**：sheet 內按「× 移除」只是**標記**（`markRemoved`／`markAllFailedRemoved`，放進記憶體的
/// `pendingRemovals`，可用 `undoRemove` 復原，墓碑列仍在 `sections`）；sheet 關閉（presenter 的
/// `onDismiss`）才呼叫 `commitRemovals()` 真的移除並落盤——標記中的項目不計入 `failedCount`／
/// `retryableFailedCount`／`remainingCount`、不參與 `retryAllRetryable()` 與回前景自動重試。
/// `pendingRemovals` 不落盤：sheet 開著時 app 被回收，重啟後 `restorePersistedEntries` 會把 manifest 裡尚未提交的紀錄
/// （含這些標記中的項目）全部還原成 `.waiting` 並自動重傳——標記不會跨行程存活（是否要「進背景即提交」屬產品／設計裁決）。
///
/// 都不打伺服器、不動 PhotoKit。**孤兒 Storage 物件（VR R3 I3）**：見 `commitRemovals()` 文件註解——本票核對後
/// 決定不在這裡刪，理由與後續寫在那裡。
extension UploadQueueStore {
    /// 標記一筆失敗項為「移除」——只對 `.failed` 生效，其他狀態 no-op（不能放棄還在飛行中或已完成的項目）。
    func markRemoved(_ id: UUID) {
        guard case .failed? = entries[id]?.state else { return }
        pendingRemovals.insert(id)
    }

    /// 復原一筆標記（墓碑列的「↶ 復原」）。
    func undoRemove(_ id: UUID) {
        pendingRemovals.remove(id)
    }

    /// 「移除這 N 張」確認後一次標記全部尚未標記的失敗項。
    func markAllFailedRemoved() {
        for id in order {
            markRemoved(id)
        }
    }

    /// sheet 關閉時呼叫：對 `pendingRemovals` 逐項移除 entry（縮圖隨之釋放）、清暫存匯出檔（影片沿
    /// `cleanupVideoTempFiles`）、讓呼叫端解除相簿登記與寶貝標記簿記（`onUploadFailedTerminal`，同
    /// `cancelPendingImportItems`；對已終局的失敗項是冪等 no-op），最後**只寫一次 manifest**、之後才刪 payload
    /// （`discardPersisted(_: [UUID])`，先 manifest 後 payload 的回收安全順序不變）。全部在同一個 MainActor
    /// 呼叫內完成。回傳實際移除的筆數。
    ///
    /// **不刪 Storage 孤兒物件（LS-410 範圍 4，VR R3 I3）**：`performUpload` 一律帶 `mediaID`（佇列項目 id），走冪等路徑，
    /// `SupabaseMediaUploadService.cleanupUnlessIdempotent` 在 INSERT 失敗時**不清**已 PUT 的原檔／縮圖——所以「PUT 成功、
    /// `media` INSERT 失敗」（`.quota` 由 trigger 擋 INSERT、`.invalidTakenAt`，以及回應遺失的 `.network`／`.server`）
    /// 確實會留下無 `media` 列的物件。這裡不清：① Notes `FBoLL` 明定 commit「不打伺服器」，刪物件要新增網路動作；
    /// ② 路徑含**上傳當下**的 UTC `yyyy/mm`（`storagePath(now:)`），佇列項目沒有記，重試跨月時無法還原；③
    /// `.network`／`.server` 無法確定 INSERT 有沒有 commit（LS-397 R2 N1：「同路徑物件只在確定失敗時清」），
    /// 刪了可能把已成功的照片變永久破圖；④ 沒有 `media` 列的物件由 LS-213 的孤兒掃描（`purge-storage`，24 小時寬限）
    /// 回收，也不計入 `storage_used_bytes`。確定失敗（`.quota`／`.invalidTakenAt`）的立即清理若要做，需要新的
    /// `MediaUploadService` 方法與落盤路徑，屬設計端／另票決定（handoff「未完成／建議」）。
    @discardableResult
    func commitRemovals() -> Int {
        let ids = order.filter { pendingRemovals.contains($0) }
        pendingRemovals = []
        var removed: [UUID] = []
        for id in ids {
            guard let entry = entries[id], case .failed = entry.state else { continue }
            if case .video(let fileURL, _)? = entry.payload {
                Self.cleanupVideoTempFiles(
                    originalURL: fileURL, uploadedURL: compressedVideoCache[id]?.fileURL ?? fileURL
                )
            }
            compressedVideoCache.removeValue(forKey: id)
            entries.removeValue(forKey: id)
            resume.tasks.removeValue(forKey: id)
            resume.attempts.removeValue(forKey: id)
            removed.append(id)
        }
        guard !removed.isEmpty else { return 0 }
        let removedSet = Set(removed)
        order.removeAll { removedSet.contains($0) }
        discardPersisted(removed)
        removed.forEach(onUploadFailedTerminal)
        advance()
        return removed.count
    }
}
