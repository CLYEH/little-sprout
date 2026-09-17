import PhotosUI
import SwiftUI

/// LS-166：`AlbumDetailView` 的 Nav Row（自畫返回鍵＋更多選單）／加入照片（Action Bar 版與
/// iPad 行內版）／PhotosPicker → `UploadQueueStore` 接線——拆到獨立檔案，同
/// `DiaryDetailView`／`DiaryDetailView+ContentActions.swift` 既有拆檔理由（`AlbumDetailView.swift`
/// 本體已有 compact／iPad 兩套版面＋Header／Meta／Grid／空狀態，疊上這條流程會超過 SwiftLint
/// `type_body_length`／`file_length` 上限）。
extension AlbumDetailView {
    // MARK: - Nav Row（自畫返回鍵＋更多選單，MJ-10）

    var navRow: some View {
        HStack {
            navBackButton
            Spacer(minLength: 0)
            if isOwner {
                moreMenu
            }
        }
    }

    private var navBackButton: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "chevron.left").appIconFrame(.medium).accessibilityHidden(true)
                Text("相簿").appFont(.body, weight: .semibold)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Color.lsTextPrimary)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                showsEditAlbum = true
            } label: {
                Label("編輯相簿名稱", systemImage: "pencil")
            }
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("刪除相簿", systemImage: "trash")
            }
        } label: {
            HStack(spacing: AppSpacing.tight) {
                Text("更多").appFont(.body, weight: .semibold)
                Image(systemName: "ellipsis").appIconFrame(.small).accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Color.lsTextPrimary)
        .accessibilityLabel("更多操作")
    }

    // MARK: - 加入照片（LS-303 R2：觸發相機膠卷批次匯入，見 `AlbumDetailView.swift` 檔頭）
    //
    // LS-315：Action Bar／iPad 行內兩版改 ref 同一元件 `ImportEntryButton`（`cmp/Button
    // Import` 第四使用點，Notes `TCs7A`：「之後的實作票應直接 ref cmp/Button Import，不得
    // 各自發明」）——取代原本各自發明的 accent 填色樣式，`isLoadingPickedItems` 停用邏輯
    // 沿用（該旗標本身已無呼叫端把它設為 true，見型別文件註解，記入 LS-96，不在本票處理）。

    var addPhotosBarButton: some View {
        // merge-review R2 M1：Action Bar 版稿面（`ve8YN`／`xcGEY`／`iXdTJ`／`EZqDj`）instance
        // 都是 `width:"fill_container"`——`fillsWidth: true` 撐滿動作帶，不是 hug-content。
        ImportEntryButton(label: "加入照片", fillsWidth: true) { showsBatchImport = true }
            .disabled(isLoadingPickedItems)
    }

    /// iPad「行內」版（Notes `rFiLJ` `RbEqx`：`width:fit_content`，不像 Action Bar 版滿版）——
    /// `ImportEntryButton` 本身即 hug-content 緊湊 pill，天然符合這個既有取捨。
    var addPhotosInlineButton: some View {
        ImportEntryButton(label: "加入照片") { showsBatchImport = true }
            // merge-review R2 m1：同 `addPhotosBarButton`——loading 期間停用，不讓使用者開出
            // 第二批 picker 跟第一批交錯。
            .disabled(isLoadingPickedItems)
    }

    /// PhotosPicker 挑選結果 → `MediaUploadService` 佇列（沿 `DiaryEditorView+Photos
    /// .loadPicked` 既有路徑，這裡不需要 20 張上限那一套——相簿沒有單篇張數上限，佇列本身的
    /// 並發／重試已經是 `UploadQueueStore` 的職責）。
    ///
    /// **merge-review R2 m1**：`isLoadingPickedItems` 包住整個迴圈——`addPhotosBarButton`／
    /// `addPhotosInlineButton` 都讀這顆旗標停用，擋下「使用者在第一批還在解碼時開第二批
    /// picker，兩批非按開始順序完成，後完成的那批把 `uploadQueueStore` 整個換掉」（同
    /// `DiaryEditorView+Photos.loadPicked` 既有的 M3／m6 修法）。
    ///
    /// **LS-237 修（池 `1aa74165` m2）**：不支援的格式（`.unsupportedFormat`）與載入失敗
    /// （`PickedItemLoader.load` 回 `nil`）原本都靜默 `continue`，使用者選 5 張佇列只出現
    /// 3 張、無任何回饋——沿 `DiaryComposerStore.unsupportedFormatSkippedCount`＋常駐回話列
    /// 的既有解法，兩種情況都算進 `skippedItemCount`（`DiaryEditorView+Photos.loadPicked`
    /// 只計 `.unsupportedFormat` 一種，這裡兩種都計，因為兩者對使用者來說是同一件事：「選了
    /// 但沒加入」，不需要細分原因）。分類邏輯抽成 `partitionPickedItems(_:)`（見該方法文件
    /// 註解）——`PhotosPickerItem` 本身無法在單元測試建構假值，但載入完成「之後」的分類
    /// 純粹是資料轉換，不需要真的跑一次 picker。
    ///
    /// **R2 訂正（merge-review R1 i1）**：`skippedItemCount` 原本只在整批載入**完成後**才
    /// 賦值——若使用者這一批還在解碼時，畫面上仍掛著「上一批」的舊回話列，會被誤以為是這一批
    /// 的結果。同 `DiaryComposerStore.beginLoadingPickedItems()` 既有作法，在新一批開始時就
    /// 先歸零。
    ///
    /// **LS-303 R4（merge-review R3 M1／M2）**：不再各自 `makeUploadQueueStore` 建立一份
    /// 專屬 store——改拿 `albumsStore.sharedUploadQueueStore(...)`（app 層級單一實例，批次
    /// 匯入過渡管線 `LegacyAlbumUploadImportCoordinator` 也拿同一份），`enqueue` 前逐筆
    /// `registerPendingAlbum` 登記要掛進哪本相簿，見 `AlbumsStore+SharedUploadQueue.swift`
    /// 檔頭文件註解（完整的併發上限／生命週期問題說明在那裡，這裡不重複）。
    @MainActor
    func loadPicked(_ items: [PhotosPickerItem], detailStore: AlbumDetailStore) async {
        isLoadingPickedItems = true
        skippedItemCount = 0
        defer { isLoadingPickedItems = false }
        var loaded: [PickedItemLoader.LoadedItem?] = []
        for item in items {
            loaded.append(await PickedItemLoader.load(item))
        }
        let (uploads, skippedCount) = Self.partitionPickedItems(loaded)
        skippedItemCount = skippedCount
        guard !uploads.isEmpty else { return }
        let queue = albumsStore.sharedUploadQueueStore(
            familyID: detailStore.familyID, mediaUploadService: mediaUploadService
        )
        uploadQueueStore = queue
        for upload in uploads {
            albumsStore.registerPendingAlbum(entryID: upload.id, albumID: detailStore.albumID)
        }
        queue.enqueue(uploads)
        showsUploadQueueSheet = true
    }

    /// 抽成靜態純函式方便單元測試（同 `CommentsSheetView.headCommentCountText` 既有慣例）
    /// ——把「載入完成後怎麼分類」跟「怎麼載入」拆開：`nil`（載入失敗）與 `.unsupportedFormat`
    /// 都算略過，其餘兩種組成 `PendingUpload` 送進上傳佇列。
    static func partitionPickedItems(
        _ loaded: [PickedItemLoader.LoadedItem?]
    ) -> (uploads: [PendingUpload], skippedCount: Int) {
        var uploads: [PendingUpload] = []
        var skippedCount = 0
        for item in loaded {
            guard let item else {
                skippedCount += 1
                continue
            }
            switch item {
            case .unsupportedFormat:
                skippedCount += 1
            case .photo(let data, let fileExtension, let pixelSize, let previewImage):
                uploads.append(PendingUpload(
                    kind: .photo(data: data, fileExtension: fileExtension), thumbnail: previewImage,
                    pixelSize: pixelSize
                ))
            case .video(let fileURL, let fileExtension, _, let pixelSize, let previewImage):
                uploads.append(PendingUpload(
                    kind: .video(fileURL: fileURL, fileExtension: fileExtension), thumbnail: previewImage,
                    pixelSize: pixelSize
                ))
            }
        }
        return (uploads, skippedCount)
    }

    /// LS-237 修（池 `1aa74165` m2）：同 `DiaryEditorView+Photos.replyRow` 既有視覺語彙
    /// （exclamationmark.circle＋note 字級），這裡不共用那支——它是 `DiaryEditorView` 的
    /// instance method，跨型別呼叫不到，同族兩處各自一份輕量視圖是這個 codebase 一貫的作法
    /// （見 `AlbumsAPIClient` 檔頭「各自完整協定」的既有先例）。
    var skippedItemsReplyRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextPrimary)
            Text("有 \(skippedItemCount) 個檔案沒有加入（格式不支援或載入失敗，僅支援 JPEG／PNG／HEIC／MP4／MOV）")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
        }
    }

    /// 刪除成功後收尾——回上一頁（列表本身仍持有舊快取，`AlbumsStore.albums` 直到下次
    /// `refresh()`／下拉更新才會少這一筆；同 `AlbumsView` 既有分工，這裡不主動觸發整批重查，
    /// 理由：使用者離開詳情頁後很快就會回到已經在畫面上的列表，若列表卡片仍短暫顯示已刪除
    /// 的這本，下次自然重新整理即可消失，屬於可接受的短暫過期，記入 handoff）。
    func albumDeleted() {
        dismiss()
    }

    // MARK: - 載入 detailStore／錯誤態（LS-237 修，池 `1aa74165` m6）

    /// `.task(id:)` 的 guard（`familyStore.myFamily?.id`／`albumSeed` 任一為 nil）落空時
    /// 原本沒有任何後續，畫面永遠停在 `ProgressView`（Rule 11 fail loud 違反）——抽成共用
    /// 方法：`.task(id:)` 第一次出現時呼叫一次，guard 落空時的「重新載入」按鈕
    /// （`seedLoadFailureState`）需要能再呼叫同一段邏輯（`.task(id:)` 只在 `albumID` 變化時
    /// 重跑，使用者手動重試不會改變 `albumID`，不能只靠它）。
    @MainActor
    func loadDetailStoreIfNeeded() async {
        guard detailStore == nil else { return }
        guard let familyID = familyStore.myFamily?.id, let seed = albumSeed else {
            seedLoadFailed = true
            return
        }
        seedLoadFailed = false
        let store = AlbumDetailStore(
            albumID: albumID, familyID: familyID, title: seed.title, childIDs: seed.childIds,
            apiClient: albumsStore.apiClient
        )
        detailStore = store
        // LS-303 R3（merge-review R2 M2）：與 `detailStore` 同一刻建立，同壽命——見
        // `LegacyAlbumUploadImportCoordinator` 檔頭文件註解「生命週期」段。
        legacyImportCoordinator = LegacyAlbumUploadImportCoordinator(
            familyID: familyID, mediaUploadService: mediaUploadService, albumsStore: albumsStore
        )
        albumsStore.subscribeDetailStore(albumID: albumID, store)
        await store.refresh()
    }

    var seedLoadFailureState: some View {
        VStack(spacing: AppSpacing.item) {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                Text("載入相簿資料失敗，請重試").appFont(.note)
            }
            .foregroundStyle(Color.lsTextPrimary)
            Button {
                Task { await loadDetailStoreIfNeeded() }
            } label: {
                Text("重新載入")
                    .appFont(.body, weight: .semibold)
                    .padding(.vertical, AppSpacing.item)
                    .padding(.horizontal, AppSpacing.item)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
