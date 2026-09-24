import SwiftUI

/// LS-166：`AlbumDetailView` 的 Nav Row（自畫返回鍵＋更多選單）／加入照片（Action Bar 版與
/// iPad 行內版）——拆到獨立檔案，同
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
    // LS-324（LS-321 使用者裁決 C1a，Notes `TCs7A` 定案段）：「加入照片」＝頁內主要動作，
    // 維持 `cmp/Button Primary`（`OKSJI`，60pt、`$accent`、加號 `image-plus`），不適用
    // `cmp/Button Import`（「同一元件＝同一角色」護欄）——改回 LS-315 之前的實心主鈕寫法。
    // Action Bar 四板（`ve8YN`／`xcGEY`／`iXdTJ`／`EZqDj`）與 iPad 行內版（`RbEqx`）稿面皆
    // ref `OKSJI`。

    var addPhotosBarButton: some View {
        PrimaryButton(icon: "photo.badge.plus", title: "加入照片") { showsBatchImport = true }
    }

    /// iPad「行內」版（Notes `rFiLJ` `RbEqx`：`width:fit_content`，不像 Action Bar 版滿版）——
    /// `PrimaryButton` 固定 `maxWidth: .infinity`，這裡沿 LS-315 前的行內 accent 寫法。
    var addPhotosInlineButton: some View {
        Button {
            showsBatchImport = true
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
        // LS-304：與 `detailStore` 同一刻建立，同壽命——見 `AlbumImportUploadCoordinator`
        // 檔頭文件註解「生命週期」段。
        importUploadCoordinator = AlbumImportUploadCoordinator(
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
