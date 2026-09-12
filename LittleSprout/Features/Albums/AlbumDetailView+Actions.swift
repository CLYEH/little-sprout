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

    // MARK: - 加入照片

    var addPhotosBarButton: some View {
        PrimaryButton(icon: "photo.badge.plus", title: "加入照片", action: { showsPhotosPicker = true })
    }

    /// iPad「行內」版（Notes `rFiLJ` `RbEqx`：`width:fit_content`，不像 Action Bar 版滿版）。
    var addPhotosInlineButton: some View {
        Button {
            showsPhotosPicker = true
        } label: {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "photo.badge.plus").appIconFrame(.medium)
                Text("加入照片").appFont(.body, weight: .semibold)
            }
            .frame(minHeight: 48)
            .padding(.horizontal, AppSpacing.item)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Color.lsOnAccent)
        .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    /// PhotosPicker 挑選結果 → `MediaUploadService` 佇列（沿 `DiaryEditorView+Photos
    /// .loadPicked` 既有路徑，這裡不需要 20 張上限／載入中旗標那一套——相簿沒有單篇張數
    /// 上限，佇列本身的並發／重試已經是 `UploadQueueStore` 的職責）。
    @MainActor
    func loadPicked(_ items: [PhotosPickerItem], detailStore: AlbumDetailStore) async {
        var uploads: [PendingUpload] = []
        for item in items {
            guard let loaded = await PickedItemLoader.load(item) else { continue }
            switch loaded {
            case .unsupportedFormat:
                continue
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
        guard !uploads.isEmpty else { return }
        let queue = uploadQueueStore ?? makeUploadQueueStore(detailStore: detailStore)
        uploadQueueStore = queue
        queue.enqueue(uploads)
        showsUploadQueueSheet = true
    }

    /// 每個 `AlbumDetailStore` 只建立一次、往後重用（`UploadQueueStore` 檔頭：飛行中的
    /// `Task` 跟著這個實例走，不是跟著 sheet 的 View 走，關閉 sheet 不會中斷上傳）。
    ///
    /// `onUploadSucceeded`（merge-review R2 M2 修正）：真正把照片掛進相簿（`album_media`
    /// INSERT）改成呼叫 `albumsStore.attachUploadedMedia`——`albumID`／`familyID` 先從
    /// `detailStore` 抽成區域變數值型別捕捉，`albumsStore` 是長生命週期物件（app 層存活，
    /// 不像 `detailStore` 是這個 View 的 `@State`），三者都不會因為使用者在上傳飛行中 pop 掉
    /// 詳情頁而消失——原本 `[weak detailStore]` 直接掛在唯一負責寫入的路徑上，detailStore
    /// deinit 後整段變成 no-op，是 M2 的根因（見 `AlbumsStore.attachUploadedMedia` 文件
    /// 註解）。`detailStore` 仍然弱引用，只用來「如果使用者還留在這個畫面，立刻讓照片牆反映
    /// 最新狀態」（`AlbumDetailStore.reflectUploadedMedia`，不重複打一次 `attachMedia`）。
    private func makeUploadQueueStore(detailStore: AlbumDetailStore) -> UploadQueueStore {
        let albumID = detailStore.albumID
        let familyID = detailStore.familyID
        let albumsStore = albumsStore
        return UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaUploadService,
            onUploadSucceeded: { [weak detailStore] _, mediaID in
                Task {
                    await albumsStore.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaID)
                    await detailStore?.reflectUploadedMedia(mediaID)
                }
            }
        )
    }

    /// 刪除成功後收尾——回上一頁（列表本身仍持有舊快取，`AlbumsStore.albums` 直到下次
    /// `refresh()`／下拉更新才會少這一筆；同 `AlbumsView` 既有分工，這裡不主動觸發整批重查，
    /// 理由：使用者離開詳情頁後很快就會回到已經在畫面上的列表，若列表卡片仍短暫顯示已刪除
    /// 的這本，下次自然重新整理即可消失，屬於可接受的短暫過期，記入 handoff）。
    func albumDeleted() {
        dismiss()
    }
}
