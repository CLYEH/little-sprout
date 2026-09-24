import Photos
import SwiftUI
import UIKit

/// 匯入整理頁（`design/littlesprout.pen` Import 01／02／03——三板「同一結構」，差別只是
/// 資料狀態：01 一般日期群、02 示範日期不明群、03 示範上限與規則提示 banner；06a 是同一
/// 畫面疊上 limited-library 提醒 banner，見 LS-251 R6 Notes「畫面級屬性」8 列＋LS-303
/// 票文範圍 3／4）。以 `.fullScreenCover` 呈現（見 `ImportBatchFlowModifier`）——全螢幕
/// 蓋版本身已經蓋掉 `RootView` 的 Tab Bar，不需要另外處理「隱藏 Tab Bar」；自訂返回列＋
/// 自訂標題（不用系統 `.navigationTitle`），同 `AlbumDetailView`／`DiaryEditorView` 既有慣例。
///
/// **未走 QA-GATE 標記**：本畫面由 `AlbumDetailView`／`TimelineView` 觸發、不是掛在
/// `RootView`／`RootView+*.swift` 的登入後全屏 gate（CLAUDE.md 硬規則界定的範圍），
/// `qa-driver-gate-check` 不適用——已核對過 `RootView.swift` 沒有新增任何綁定。
struct ImportOrganizeView: View {
    let childrenStore: ChildrenStore
    let albumsStore: AlbumsStore
    let uploadCoordinator: ImportUploadCoordinator
    let accessState: PhotoLibraryAccessState
    let assetLimit: Int
    /// LS-303 R2（merge-review R1 M1）：`nil` 時（harness／preview）縮圖格全部退回系統圖示
    /// 佔位，見 `ImportThumbnailCell`。呼叫端（`ImportBatchFlowModifier`）在 MainActor
    /// context 建好實例才傳進來——`ImportThumbnailProvider` 本身是 `@MainActor` class，
    /// 不能在這個 `init`（非 async，不保證 MainActor）裡現建。
    let thumbnailProvider: ImportThumbnailProvider?
    /// LS-303 R2（merge-review R1 i3）：PHPicker 選取結果沒有 `itemIdentifier` 的筆數——
    /// 不再塞假 UUID 進 `ImportPlan`（會讓主鈕 N 與摘要多算出查無此圖的筆），改成整筆捨棄
    /// 並在畫面上提示，見 `droppedItemsReplyRow`。
    let droppedCount: Int
    /// LS-303 R5（merge-review R4 i2）：入口來源已知的相簿 id／名稱——傳給
    /// `ImportGroupCardView` 當 `albums` 清單還沒載入完成時的 fallback 顯示，見該檔
    /// `albumLabel` 文件註解。`.timeline`／harness `init(plan:...)` 皆為 nil。
    let fallbackAlbumID: UUID?
    let fallbackAlbumName: String?
    /// LS-304：主鈕按下、`uploadCoordinator.startImport(plan:)` 拿到 `ImportBatchSession`
    /// 之後呼叫——`ImportBatchFlowContainer` 用它把流程轉場到 04 進度頁（見該檔文件註解）。
    /// 預設空閉包：harness／`#Preview`／`.timeline` 入口尚未接線時不需要真的轉場。
    var onImportStarted: (ImportBatchSession) -> Void = { _ in }

    @State private var plan: ImportPlan
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        childrenStore: ChildrenStore, albumsStore: AlbumsStore, uploadCoordinator: ImportUploadCoordinator,
        pickedAssets: [ImportDateGrouping.PickedAsset], entrySource: ImportEntrySource,
        thumbnailProvider: ImportThumbnailProvider?, droppedCount: Int = 0,
        accessState: PhotoLibraryAccessState, assetLimit: Int = 200,
        onImportStarted: @escaping (ImportBatchSession) -> Void = { _ in }
    ) {
        self.childrenStore = childrenStore
        self.albumsStore = albumsStore
        self.uploadCoordinator = uploadCoordinator
        self.accessState = accessState
        self.assetLimit = assetLimit
        self.thumbnailProvider = thumbnailProvider
        self.droppedCount = droppedCount
        self.fallbackAlbumID = entrySource.defaultAlbumID
        self.fallbackAlbumName = entrySource.defaultAlbumName
        self.onImportStarted = onImportStarted
        // LS-303 R2（merge-review R1 M2，orchestrator 裁決 `c997f234`）：從相簿詳情進入時
        // 每群預設放進該相簿（可改）；其餘入口（目前只有 `.timeline`，本票無呼叫點）維持
        // C3a「預設不放相簿」——`applyDefaultAlbum` 是純函式，見 `ImportEntrySourceTests`。
        let groups = entrySource.applyDefaultAlbum(to: ImportDateGrouping.group(pickedAssets))
        _plan = State(initialValue: ImportPlan(groups: groups))
    }

    /// harness／preview 用：已經分好組的固定 plan，不需要真的餵 `PickedAsset`（LS-303
    /// 硬規則：新畫面要能被 `TapTargetGateHarness` 免登入建構，PHAsset 無法在 preview 世界
    /// 合成——分組完成後的 `ImportPlan` 是純資料，這個入口讓 harness／`#Preview` 可以直接
    /// 帶入固定 fixture，不受這個限制）。
    init(
        childrenStore: ChildrenStore, albumsStore: AlbumsStore, uploadCoordinator: ImportUploadCoordinator,
        plan: ImportPlan, accessState: PhotoLibraryAccessState, assetLimit: Int = 200,
        thumbnailProvider: ImportThumbnailProvider? = nil,
        onImportStarted: @escaping (ImportBatchSession) -> Void = { _ in }
    ) {
        self.childrenStore = childrenStore
        self.albumsStore = albumsStore
        self.uploadCoordinator = uploadCoordinator
        self.accessState = accessState
        self.assetLimit = assetLimit
        self.thumbnailProvider = thumbnailProvider
        self.droppedCount = 0
        self.fallbackAlbumID = nil
        self.fallbackAlbumName = nil
        self.onImportStarted = onImportStarted
        _plan = State(initialValue: plan)
    }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            ScrollView {
                // merge-review R1 M4：改 `LazyVStack`——200 張分 200 群的極端情況（本票自己的
                // `ImportDateGroupingTests.test_group_twoHundredAssets_preservesFullCountAcrossGroups`
                // 示範過）在非 lazy 的 `VStack` 下會一次具現化 200 張群卡，開整理頁當下主執行緒
                // 卡頓。
                LazyVStack(alignment: .leading, spacing: AppSpacing.block) {
                    summaryHeader
                    if droppedCount > 0 { droppedItemsReplyRow }
                    if accessState == .limited { limitedLibraryBanner }
                    rulesBanner
                    if plan.totalAssetCount >= assetLimit { limitReachedBanner }
                    ForEach($plan.groups) { $group in
                        ImportGroupCardView(
                            group: $group, children: childrenStore.activeChildren, albums: albumsStore.albums,
                            maxThumbnailSlots: thumbnailSlots, thumbnailCellSize: thumbnailCellSize,
                            thumbnailProvider: thumbnailProvider, fallbackAlbumID: fallbackAlbumID,
                            fallbackAlbumName: fallbackAlbumName
                        )
                    }
                }
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.bottom, AppSpacing.block)
                // LS-251 R6 Notes「畫面級屬性」01/02/03 列：iPad「560pt 置中欄」——「iPad 是
                // 重排不是放大」（LS-142 Q7HrnF 慣例），內容欄本身收窄置中，不是整頁滿版拉大字。
                .frame(maxWidth: horizontalSizeClass == .regular ? 560 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .appBackground()
        .safeAreaInset(edge: .bottom) { ctaBar }
    }

    /// merge-review R2 i4／R4 修正：`ImportThumbnailGridView` 的欄寬自 i5 起是 `.flexible()`
    /// （見該檔文件註解），實際格子寬度在 iPad regular size class 下明顯大於 iPhone 那份
    /// 96pt——縮圖請求的 `targetSize` 若仍寫死 96×displayScale，iPad 上會要到偏小的縮圖再
    /// 放大顯示、偏糊。這裡依 size class 給不同的請求解析度提示值（寧可多要一點、不要不夠：
    /// `PHImageManager` 對「偏大」的請求只是多花一點解碼成本，不會像「偏小」那樣看起來模糊）。
    private var thumbnailCellSize: CGFloat {
        horizontalSizeClass == .regular ? 160 : 96
    }

    private var thumbnailSlots: Int {
        horizontalSizeClass == .regular
            ? ImportThumbnailLayout.regularMaxSlots : ImportThumbnailLayout.compactMaxSlots
    }

    // MARK: - 自訂 Nav Row（自訂標題，不用系統 `.navigationTitle`）

    private var navRow: some View {
        HStack {
            // LS-303：`Button("取消"){}.frame(minHeight:)` 這種「字串初始化＋外掛 frame」寫法
            // 熱區鎖死在文字天然大小（同 `DiaryDatePickerSheet` 既有踩雷記錄）——改用
            // `Button{}label:{}`，`.frame(minHeight:).contentShape(Rectangle())` 做在 label
            // 內部才會撐大熱區（`AlbumDetailView+Actions.navBackButton` 既有寫法）。
            Button {
                dismiss()
            } label: {
                Text("取消").appFont(.body, weight: .semibold)
                    .frame(minWidth: 44, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.lsTextPrimary)
            Spacer(minLength: AppSpacing.label)
            Text("整理新照片").appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: AppSpacing.label)
            // 對齊用的隱形佔位，讓標題視覺置中（同 `AlbumDetailView` Nav Row 既有排法）。
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.label)
    }

    private var summaryHeader: some View {
        Text("共 \(plan.totalAssetCount) 張・\(plan.groupCount) 個日期群")
            .appFont(.lead, weight: .bold)
            .foregroundStyle(Color.lsTextPrimary)
            .padding(.top, AppSpacing.label)
    }

    /// merge-review R1 i3：`itemIdentifier` 缺失的筆數不再塞假 id 進 `ImportPlan`（會讓
    /// 「共 N 張」比實際可匯入的張數多），改成整筆捨棄並在這裡告知使用者——同
    /// `DiaryEditorView+Photos.replyRow` 既有視覺語彙（exclamationmark.circle
    /// ＋note 字級）。
    private var droppedItemsReplyRow: some View {
        HStack(spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                .foregroundStyle(Color.lsTextPrimary)
            Text("有 \(droppedCount) 個項目讀不到、沒有加入")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
        }
    }

    // MARK: - Banners

    /// 06a：limited-library 提醒——標題沿用 R1「值得保留」第 5 條既有裁決（不用
    /// limited-library 術語），內文＝R3 MN-17 逐字修正版。動作呼叫
    /// `PHPhotoLibrary.presentLimitedLibraryPicker`（票文範圍 4 指定 API）；banner 本身的
    /// 文案字面寫「到「設定」調整」，但票文範圍 4 明確要求呼叫這支 API
    /// 而非跳轉系統設定——兩者字面不完全一致，已在 handoff 風險段記錄，
    /// 以票文範圍 4 的 API 指定為準。
    private var limitedLibraryBanner: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "circle.alert").appIconFrame(.small).foregroundStyle(Color.lsTextPrimary)
                Text("只能看到部分照片").appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            }
            Text("目前只能看到你挑選過的那些照片。想讓更多照片進來，可以在這裡調整。")
                .appFont(.note).foregroundStyle(Color.lsTextSecondary)
            Button {
                presentLimitedLibraryPicker()
            } label: {
                Text("管理可存取的照片").appFont(.note, weight: .semibold)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
            }
        }
        .padding(AppSpacing.item)
        .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    /// 03：規則提示（C2a 使用者裁決照稿定案）——資訊提示，非錯誤，恆顯示。
    private var rulesBanner: some View {
        Text("影片最長 1 分鐘。HEIC 相片會轉成一般照片；Live Photo 會保留照片與短片。")
            .appFont(.note)
            .foregroundStyle(Color.lsTextSecondary)
            .padding(AppSpacing.item)
            .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    /// C1a 使用者裁決（維持 200 張）——達上限時的溫和提示，非錯誤。
    private var limitReachedBanner: some View {
        Text("已達單次上限 \(assetLimit) 張，其餘照片請稍後再匯入一次。")
            .appFont(.note, weight: .semibold)
            .foregroundStyle(Color.lsTextPrimary)
            .padding(AppSpacing.item)
            .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    // MARK: - 釘底主鈕（93pt，Notes「畫面級屬性」01 列）

    /// LS-303 R5（merge-review R4 i4）：全部群都被略過時 `pendingAssetCount == 0`——同樣是
    /// 使用者可修正的狀態（取消略過任一群即可），非本票 M3 finding 所指「這批一張都沒有的
    /// in-flight 概念」，改回品牌不可協商第 8 條同一套 idiom：不 disable，按下才提示
    /// （LS-303 R4 merge-review R3 M3，orchestrator 裁決 `8579e30e` 收回 R3 的「主鈕
    /// disabled」；同 `ImportGroupCardView` 寶貝 chip 那套回話列 idiom）——主鈕永遠可按，按下
    /// 時才判斷：條件不成立就顯示回話列並停留整理頁，不呼叫 `uploadCoordinator.startImport`／
    /// 不進下一態。
    private var noPendingAssets: Bool { plan.pendingAssetCount == 0 }

    /// 使用者已經按過一次主鈕、但當下沒有任何要匯入的照片——`noPendingAssets` 一旦回到
    /// false（使用者取消略過任一群）這個回話列就跟著消失，不需要另外重置。
    @State private var didAttemptImportWithNoPendingAssets = false

    private var ctaBar: some View {
        VStack(spacing: AppSpacing.tight) {
            if didAttemptImportWithNoPendingAssets && noPendingAssets {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                        .foregroundStyle(Color.lsTextPrimary)
                    Text("沒有要匯入的照片，先取消一個略過的日期")
                        .appFont(.note).foregroundStyle(Color.lsTextPrimary)
                }
            }
            Button {
                guard !noPendingAssets else {
                    didAttemptImportWithNoPendingAssets = true
                    return
                }
                // LS-304：不再 `dismiss()`——整理頁是批次匯入流程（`ImportBatchFlowContainer`）
                // 的起始態，按下主鈕後轉場到 04 進度頁（同一個 `.fullScreenCover` 內的狀態
                // 切換，不是關掉再開新的一個），見該檔文件註解「為什麼不用 NavigationStack／
                // 循序 fullScreenCover」段。
                onImportStarted(uploadCoordinator.startImport(plan: plan))
            } label: {
                Text("開始匯入 \(plan.pendingAssetCount) 張")
                    .appFont(.body, weight: .bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingCTA)
            }
            .foregroundStyle(Color.lsOnAccent)
            .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.vertical, AppSpacing.item)
        .background(Color.lsSurface)
    }

    @MainActor
    private func presentLimitedLibraryPicker() {
        let activeScene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
        guard
            let scene = activeScene as? UIWindowScene,
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }
}

#if DEBUG
#Preview("預設") {
    ImportOrganizeView(
        childrenStore: .preview(), albumsStore: .preview(), uploadCoordinator: NoOpImportUploadCoordinator(),
        plan: ImportPlan.previewFixture, accessState: .authorized
    )
}

#Preview("Limited Library") {
    ImportOrganizeView(
        childrenStore: .preview(), albumsStore: .preview(), uploadCoordinator: NoOpImportUploadCoordinator(),
        plan: ImportPlan.previewFixture, accessState: .limited
    )
}

extension ImportPlan {
    static var previewFixture: ImportPlan {
        ImportPlan(groups: [
            ImportPlan.Group(
                id: "2026-09-10", anchorDate: Date(), isDateUnknown: false,
                assetLocalIdentifiers: (0..<23).map { "id-\($0)" }
            ),
            ImportPlan.Group(
                id: "2026-09-08", anchorDate: Date().addingTimeInterval(-2 * 86400), isDateUnknown: false,
                assetLocalIdentifiers: (0..<5).map { "id-b-\($0)" }
            ),
            ImportPlan.Group(
                id: ImportDateGrouping.unknownDateGroupID, anchorDate: Date(), isDateUnknown: true,
                assetLocalIdentifiers: (0..<3).map { "id-c-\($0)" }
            )
        ])
    }
}
#endif
