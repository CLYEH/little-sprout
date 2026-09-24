import SwiftUI

/// LS-315：Header「匯入」鈕——抽到獨立檔案（同 `TimelineView+Comments.swift` 既有先例：
/// `TimelineView.swift` 本體已經有卡片流／篩選／分頁三段邏輯，疊上這顆會超過 SwiftLint
/// `file_length`）。
extension TimelineView {
    /// Header「匯入」鈕（`ImportEntryButton`，`cmp/Button Import` `o8zYlX`）——沿
    /// `ImportEntrySource.timeline`（C3a：任何入口預設不放相簿）接上 LS-303 既有 PHPicker
    /// 流程，見型別文件註解「LS-315」段。三處 timeline instance 統一
    /// `accessibilityIdentifier`（Notes `MCbLu`：避免各自發明不同字串）。
    var importEntryButton: some View {
        ImportEntryButton(label: "匯入") {
            showsImportBatch = true
            // merge-review R2 M2：時間軸這條路徑上沒有任何人載過相簿清單（唯一填值來源
            // `AlbumsStore.refresh`／`loadMore` 只有 `AlbumsView` 呼叫）——冷啟動直接停在
            // 時間軸、沒逛過相簿 tab 就點「匯入」，整理頁每群的相簿選單只剩「不放相簿」。
            // R3（merge-review R2 m1／m2）：守門邏輯下沉到 `AlbumsStore.refreshIfEmpty(familyID:)`
            // （空且非 in-flight 才打）——`@Observable` 讓晚到的清單自動更新整理頁選單，不需要
            // 額外訂閱。
            if let familyID = familyStore.myFamily?.id {
                Task { await albumsStore.refreshIfEmpty(familyID: familyID) }
            }
        }
        .accessibilityIdentifier(QAAccessibilityID.timelineImportPhotos)
    }

    /// R3（merge-review R2 M1）：`.importBatchFlow` 的 `uploadCoordinator` 引數解析——抽出成
    /// 純函式，讓「NoOp 只在 `importUploadCoordinator` 還沒建立好之前當保底」這件事可以用
    /// 型別斷言驗證（`TimelineImportUploadCoordinatorTests`），不必靠原始碼字串比對（同
    /// `AlbumsStoreTests.test_refreshIfEmpty_*` 取代原始碼字面守衛的理由——這裡一開始就換成
    /// 能做到行為測試的寫法）。
    static func resolveUploadCoordinator(_ real: AlbumImportUploadCoordinator?) -> ImportUploadCoordinator {
        real ?? NoOpImportUploadCoordinator()
    }

    /// `.task(id: familyStore.myFamily?.id)` 用（`TimelineView.swift`）——把 R3 新增的
    /// coordinator 建立塞進既有的那顆 `.task`，不另外疊一個（同一個 familyID 只需要跑一次）。
    /// guard 同 `AlbumDetailView.loadDetailStoreIfNeeded()` 既有寫法，避免同一個家庭時反覆
    /// 重建（`TimelineView` 是 tab-root，跟 `AlbumDetailView` 每次進場才建立一次不同壽命）。
    func refreshChildrenAndEnsureImportCoordinator(familyID: UUID) async {
        if importUploadCoordinator == nil {
            importUploadCoordinator = AlbumImportUploadCoordinator(
                familyID: familyID, mediaUploadService: mediaUploadService, albumsStore: albumsStore
            )
        }
        await childrenStore.refresh(familyID: familyID)
    }

    /// LS-328：搬自 `TimelineView.swift`（同檔頭理由，`TimelineView.swift` 已頂 SwiftLint
    /// `file_length` 上限，抽這支騰出空間給批次匯入 `onAppear`／`onDisappear` 兩行）——內容
    /// 本身未改動。不是 `private`：跨檔案 extension 存取層級，同 `importEntryButton`。
    ///
    /// merge-review R1 m1：`refreshState == .failure` 之前跟「還沒有回憶」共用同一個空狀態
    /// 文案——離線或 RPC 500 會被呈現成「你家還沒有內容」，且沒有重試入口。失敗時改顯示
    /// 錯誤訊息＋「重新載入」，跟 `DiaryDetailView` 的行內錯誤提示一致（同一套語彙：
    /// `$text-primary` ＋ circle-alert，不用 danger，見 brand skill 規則 8）。
    @ViewBuilder
    var emptyOrLoadingState: some View {
        switch timelineStore.refreshState {
        case .submitting:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .failure(let error):
            VStack(spacing: AppSpacing.item) {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                    Text(error.userFacingMessage).appFont(.note)
                }
                .foregroundStyle(Color.lsTextPrimary)
                // merge-review R2-M2：同 `loadMoreTrigger` 的「重新載入」——label closure
                // 加 padding＋`contentShape`，不是裸 `Button(_:action:)`。merge-review R3
                // r3-m1：padding token 同上方 `loadMoreTrigger` 的理由，改用
                // `AppSpacing.item`（同 `SettingsView` 登出鈕），命中區 ≈52.3pt。
                Button {
                    Task {
                        guard let familyID = familyStore.myFamily?.id else { return }
                        await timelineStore.refresh(familyID: familyID, childID: selectedChildID)
                    }
                } label: {
                    Text("重新載入")
                        .appFont(.body, weight: .semibold)
                        .padding(.vertical, AppSpacing.item)
                        .padding(.horizontal, AppSpacing.item)
                        .contentShape(Rectangle())
                }
            }
            .frame(maxWidth: .infinity)
        case .idle, .success:
            // LS-315：文案改依 Notes `F77gCE`（00b 空狀態）逐字抄值，「匯入」領頭、不加按鈕
            // （C1c 裁決：空狀態不另造 CTA，靠文案指路到 Header 既有兩顆入口鈕）——00b 板
            // 完整的「Empty Print」卡面視覺（相框樣式、獨立標題／壓印小字）不在本票範圍，
            // Body 幾何各依來源板不追齊（見票文範圍 5、Notes `MCbLu`），標題另依 `tZQNc` 抄值。
            ContentUnavailableView(
                "這裡還沒有任何回憶",
                systemImage: "photo.stack",
                description: Text("點上方的「匯入」把手機裡的舊照片搬進來，或點「新增回憶」寫下第一篇日記。")
            )
        }
    }
}
