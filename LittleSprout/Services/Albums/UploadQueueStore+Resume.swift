import Foundation

/// LS-397（LS-20 背景續傳，路線 (b)）：回前景自動重送、落盤與重啟後還原——拆成獨立檔案，理由同
/// `UploadQueueStore+VideoExportSlot.swift`：主檔逼近 SwiftLint `file_length` 上限。`finish(_:state:)`
/// ／`releasesPayload(for:)`／`entries`／`order`／`advance()` 因此不能是 `private`。
///
/// **為什麼要「嘗試編號」（attempt）**：回前景時把卡在 `.uploading` 的項目翻回 `.waiting` 重送，
/// 但舊的 `Task` 不一定真的死了——app 只是被暫停，舊請求可能在回前景後才完成或失敗。三種交錯
/// 都在 MainActor 上序列化處理，靠 attempt 編號與當下狀態決定誰算數：
/// - 舊嘗試**失敗**（含被我們 `cancel()` 造成的 `CancellationError`）：編號已過期或狀態不再是
///   `.uploading` → 丟棄，不能把重送中的項目誤標成失敗。
/// - 舊嘗試**成功**（位元組其實送完了）：算數——標 `.completed` 並取消重送中的新嘗試；不然新
///   嘗試會再傳一份，`media` 多一列重複照片。
/// - 新嘗試成功時項目已被舊嘗試標成 `.completed`：不重複呼叫 `onUploadSucceeded`（相簿掛載
///   與時間軸通知只做一次）。
/// 已經送出的請求無法保證伺服器端沒收到（例如回應遺失後才被取消）——這條路徑是 at-least-once，
/// 真正的去重需要伺服器端冪等鍵，不在本票範圍（記入 handoff）。
extension UploadQueueStore {
    struct ResumeState {
        /// 飛行中的 `Task` 參照——回前景時取消舊嘗試；`start(_:)` 是唯一寫入點。
        var tasks: [UUID: Task<Void, Never>] = [:]
        var attempts: [UUID: Int] = [:]
        /// 進背景那一刻仍在飛行中的項目 id——回前景時只重送這些（不是所有 `.uploading`／
        /// 可重試失敗，避免把使用者早就看過的舊失敗項自動重送）。
        var inFlightAtBackground: Set<UUID> = []
        /// 尚未終局、已落盤的紀錄（key＝entry id）；`persistManifest()` 依 `order` 輸出。
        var records: [UUID: PersistedUploadRecord] = [:]
    }

    // MARK: - 嘗試編號與結果套用

    func beginAttempt(_ id: UUID) -> Int {
        let next = (resume.attempts[id] ?? 0) + 1
        resume.attempts[id] = next
        return next
    }

    func completeUpload(_ id: UUID, attempt: Int, mediaID: UUID) {
        // 已經被另一次嘗試標成完成：不重複觸發掛鉤（見檔頭第三條）。
        if case .completed? = entries[id]?.state { return }
        // 舊嘗試的成功仍算數；此時若已有新嘗試在飛，取消它避免重複上傳（見檔頭第二條）。
        if attempt != resume.attempts[id] { resume.tasks[id]?.cancel() }
        resume.tasks[id] = nil
        onUploadSucceeded(id, mediaID)
        finish(id, state: .completed)
    }

    func failUpload(_ id: UUID, attempt: Int, reason: UploadFailureReason) {
        // 過期嘗試（已被回前景翻回 `.waiting`／重送，或項目已完成）的失敗一律丟棄。
        guard attempt == resume.attempts[id], case .uploading? = entries[id]?.state else { return }
        resume.tasks[id] = nil
        finish(id, state: .failed(reason))
    }

    // MARK: - 進背景／回前景

    /// `RootView` 的 `scenePhase == .background` 呼叫：記下此刻飛行中的項目。只有真的進過背景
    /// 才會重送——`.inactive`（下拉通知中心、系統對話框）不算，那段時間上傳沒有被中斷。
    func appDidEnterBackground() {
        resume.inFlightAtBackground = Set(order.filter { id in
            if case .uploading? = entries[id]?.state { true } else { false }
        })
    }

    /// `RootView` 的 `scenePhase == .active` 呼叫：把進背景時飛行中、現在仍卡在 `.uploading`
    /// （被暫停的請求）或已被系統中斷成 `.failed(.network)`（`-1005`）的項目取消舊嘗試、翻回
    /// `.waiting` 重送，並讓續傳橫幅出現。沒有需要重送的項目時什麼都不做（橫幅不出現）。
    func appDidBecomeActive() {
        let candidates = resume.inFlightAtBackground
        resume.inFlightAtBackground = []
        var resumedAny = false
        for id in order where candidates.contains(id) {
            guard var entry = entries[id], entry.payload != nil else { continue }
            switch entry.state {
            case .uploading, .failed(.network): break
            case .waiting, .completed, .failed: continue
            }
            resume.tasks[id]?.cancel()
            resume.tasks[id] = nil
            entry.state = .waiting
            entries[id] = entry
            resumedAny = true
        }
        guard resumedAny else { return }
        resumedFromInterruption = true
        advance()
    }

    // MARK: - 落盤

    func persistEnqueued(_ upload: PendingUpload, enqueuedAt: Date) {
        guard let persistence,
              let fileName = persistence.storePayload(id: upload.id, kind: upload.kind) else { return }
        let ext: String
        let kind: PersistedUploadRecord.Kind
        switch upload.kind {
        case .photo(_, let fileExtension): (kind, ext) = (.photo, fileExtension)
        case .video(_, let fileExtension): (kind, ext) = (.video, fileExtension)
        }
        resume.records[upload.id] = PersistedUploadRecord(
            id: upload.id, kind: kind, fileExtension: ext, payloadFileName: fileName,
            pixelWidth: upload.pixelSize.width, pixelHeight: upload.pixelSize.height,
            takenAt: upload.takenAt, enqueuedAt: enqueuedAt, albumID: albumIDProvider(upload.id)
        )
    }

    /// 依 `order` 輸出尚未終局（`records` 裡還有的）項目——終局時 `discardPersisted` 已把它移出。
    func persistManifest() {
        guard let persistence else { return }
        persistence.save(order.compactMap { resume.records[$0] })
    }

    /// 這筆終局（完成、不可重試失敗、取消匯入）：先寫 manifest 再刪 payload——中間被回收時
    /// 最壞是 manifest 少一筆而留下孤兒檔（下次還原時 `pruneOrphans` 清掉），不會是 manifest
    /// 指向已刪除的檔案。
    func discardPersisted(_ id: UUID) {
        guard let record = resume.records.removeValue(forKey: id), let persistence else { return }
        persistence.save(order.compactMap { resume.records[$0] })
        persistence.removePayload(named: record.payloadFileName)
    }

    /// 登出：取消所有飛行中的嘗試並整個清掉落盤目錄（`AlbumsStore.reset()`）。
    func discardPersistedState() {
        resume.tasks.values.forEach { $0.cancel() }
        resume = ResumeState()
        persistence?.destroy()
    }

    // MARK: - 重啟後還原

    /// app 被回收後重新啟動：把 manifest 裡的未完成項列回佇列（狀態一律 `.waiting`，縮圖為空）、
    /// 逐筆呼叫 `registerAlbum` 讓呼叫端重新登記相簿對照，設 `resumedFromInterruption` 並開始重送。
    /// 不接回舊的 `URLSession`（路線 (a)）——整筆重傳。payload 檔案不見的紀錄直接丟棄。
    func restorePersistedEntries(registerAlbum: (_ entryID: UUID, _ albumID: UUID) -> Void) {
        guard let persistence else { return }
        var restored = 0
        for record in persistence.loadRecords() where entries[record.id] == nil {
            guard let kind = persistence.payload(for: record) else { continue }
            entries[record.id] = Entry(
                thumbnail: nil, pixelSize: PixelSize(width: record.pixelWidth, height: record.pixelHeight),
                payload: kind, enqueuedAt: record.enqueuedAt, state: .waiting, takenAt: record.takenAt
            )
            order.append(record.id)
            resume.records[record.id] = record
            if let albumID = record.albumID { registerAlbum(record.id, albumID) }
            restored += 1
        }
        persistence.pruneOrphans(keeping: Set(resume.records.values.map(\.payloadFileName)))
        persistManifest()
        guard restored > 0 else { return }
        resumedFromInterruption = true
        advance()
    }
}
