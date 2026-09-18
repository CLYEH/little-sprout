import Foundation

/// LS-303 R4（merge-review R3 M1／M2，orchestrator 裁決 `8579e30e`）：「加入照片」單張即傳
/// （`AlbumDetailView+Actions.loadPicked`）與批次匯入過渡管線（`LegacyAlbumUploadImportCoordinator`，
/// LS-304 已移除、由 `AlbumImportUploadCoordinator` 取代——下面 M1／M2 兩段描述的是當時 R3
/// 版本的問題與修法，非現況呼叫端，見 merge-review R1 i5）改共用同一份 app 層級
/// `UploadQueueStore`（掛在 `AlbumsStore`——`LittleSproutApp.swift`
/// 唯一建構點、登入後一路存活到登出，同 `attachUploadedMedia` 本來就是 `AlbumsStore` 的職責），
/// 不再各自 new 一份：
///
/// - **M1（併發上限被拆散）**：`UploadQueueStore` 的 `maxConcurrentUploads`／影片 export 名額
///   （LS-286 i2／LS-288 i3）都是**實例級**旗標。R3 版本對每個日期群各 new 一份 store，200 張
///   分 20 群就變成「20 份 store 各自 3 筆併發」＝最多 60 筆同時上傳、20 支影片同時 export。
///   改用單一實例後，閘門回到票文與 LS-286／LS-288 設計時假設的「整個 app 同時只有一份佇列」。
/// - **M2（PLAUSIBLE：離開畫面後整批靜默消失）**：R3 版本裡 store 的唯一強引用來自
///   `LegacyAlbumUploadImportCoordinator.activeQueues`，而 coordinator 本身是
///   `AlbumDetailView` 的 `@State`——使用者在讀取位元組期間離開畫面、`AlbumDetailView` 被
///   pop，coordinator 與 store 一起被釋放，尚未開始執行的 `[weak self]` 上傳 Task 全部
///   silently return。掛在 `AlbumsStore` 之後，store 的生命週期不再跟著任何畫面走。
///
/// **`entry id → albumID` 對照表**：單一 store 現在可能同時服務「使用者剛才在相簿 A 加的
/// 照片」與「使用者現在在相簿 B 批次匯入的照片」，`onUploadSucceeded` 不能像各自持有一份時
/// 那樣把 `albumID` 直接寫死在 closure 裡——呼叫端在 `store.enqueue(uploads)` **之前**先呼叫
/// `registerPendingAlbum(entryID:albumID:)` 登記，`onUploadSucceeded` 查表決定掛哪本，查到
/// 後立刻 `removeValue`（同一個 entry id 不會重複觸發 `attachUploadedMedia`）。
extension AlbumsStore {
    /// 取得（必要時建立）app 層級共用的 `UploadQueueStore`。`familyID`／`mediaUploadService`
    /// 只在第一次呼叫（真的要建立）時生效——同一個登入 session 內所有呼叫端都源自同一個
    /// 已登入 family／service，這裡不重複校驗。
    @MainActor
    func sharedUploadQueueStore(familyID: UUID, mediaUploadService: MediaUploadService) -> UploadQueueStore {
        if let existing = sharedUploadQueueStoreInstance { return existing }
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaUploadService,
            onUploadSucceeded: { [weak self] entryID, mediaID in
                guard let self, let albumID = self.pendingUploadAlbumIDs.removeValue(forKey: entryID) else { return }
                Task { await self.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaID) }
            },
            // LS-303 R5（merge-review R4 i1）：不可重試失敗終局同樣從對照表移除，理由見
            // `UploadQueueStore.onUploadFailedTerminal` 文件註解。
            onUploadFailedTerminal: { [weak self] entryID in
                self?.pendingUploadAlbumIDs.removeValue(forKey: entryID)
            }
        )
        sharedUploadQueueStoreInstance = store
        return store
    }

    /// 呼叫端在 `store.enqueue(uploads)` **之前**對每一筆 `PendingUpload` 呼叫，登記這筆
    /// entry id 完成後要掛進哪本相簿（見檔頭文件註解）。
    @MainActor
    func registerPendingAlbum(entryID: UUID, albumID: UUID) {
        pendingUploadAlbumIDs[entryID] = albumID
    }
}
