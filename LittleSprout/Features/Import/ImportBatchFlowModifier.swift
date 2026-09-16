import PhotosUI
import SwiftUI

/// 相機膠卷批次匯入「選取→整理」的入口串接（LS-303 範圍 1／4）——把「請求相片庫授權
/// →（`.denied` 就攔在 06b／否則開 PHPicker）→ 依 `itemIdentifier` 反查 EXIF 分組
/// → 開整理頁」這串流程包成一個 `ViewModifier`，讓呼叫端只需要加一顆觸發鈕＋掛這個
/// modifier，不用各自重寫一次這串邏輯。
///
/// **LS-303 R2（merge-review R1 M2，orchestrator 裁決 `c997f234`）**：時間軸批次匯入入口
/// 移出本票（另開 lane:design 決策票，有稿再接），目前唯一呼叫端是 `AlbumDetailView`。
///
/// `isActive` 由呼叫端的按鈕觸發（設為 `true`）；本 modifier 自己在流程跑完（或使用者取消）
/// 後把它撥回 `false`，呼叫端不需要自己管理中繼狀態。
struct ImportBatchFlowModifier: ViewModifier {
    @Binding var isActive: Bool
    let childrenStore: ChildrenStore
    let albumsStore: AlbumsStore
    let entrySource: ImportEntrySource
    var uploadCoordinator: ImportUploadCoordinator = NoOpImportUploadCoordinator()

    @State private var accessState: PhotoLibraryAccessState = .authorized
    @State private var showsPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showsDenied = false
    /// merge-review R1 M6／實機除錯訂正：整理頁改用 `.fullScreenCover(item:)` 而非
    /// `.fullScreenCover(isPresented:)`＋一串各自獨立的 `@State`——後者的 content closure
    /// 在 `body(content:)` 最後一次求值當下就把 `self` 的屬性讀值「凍結」進閉包，實機測到
    /// `presentOrganizeIfReady()` 剛設完 `droppedCount=1`、閉包實際執行時卻讀到 0（`pickedAssets`
    /// 同理），是這個 modifier struct 在非同步 Task 完成前後被 `AlbumDetailView.body` 重新
    /// 求值、拿到舊快照的 closure 之故。`.fullScreenCover(item:)` 把整批資料收進一個
    /// `Identifiable` payload、以參數傳進 content closure，動態求值時一定拿到當下的值，
    /// 徹底避開這類 stale-closure-capture。
    @State private var organizePayload: OrganizePayload?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { _, newValue in
                guard newValue else { return }
                isActive = false
                Task { await requestAccessAndProceed() }
            }
            .photosPicker(
                isPresented: $showsPicker, selection: $pickerSelection, maxSelectionCount: 200,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: pickerSelection) { _, items in
                guard !items.isEmpty else { return }
                // `itemIdentifier` 讀取留在 MainActor（見 `PhotoLibraryAccessService
                // .identifiers(for:)` 文件註解）——只有純 `[String]` 離開 MainActor。
                let (identifiers, droppedCount) = PhotoLibraryAccessService.identifiers(for: items)
                pickerSelection = []
                Task {
                    // merge-review R1 M5：`PHAsset.fetchAssets`／`enumerateObjects` 是同步
                    // Photos 資料庫查詢，離開 MainActor 才不會卡住整理頁開啟前的主執行緒。
                    let result = await Task.detached(priority: .userInitiated) {
                        PhotoLibraryAccessService.fetchResult(for: identifiers, droppedCount: droppedCount)
                    }.value
                    presentOrganize(with: result)
                }
            }
            .fullScreenCover(item: $organizePayload) { payload in
                ImportOrganizeView(
                    childrenStore: childrenStore, albumsStore: albumsStore, uploadCoordinator: uploadCoordinator,
                    pickedAssets: payload.pickedAssets, entrySource: entrySource,
                    thumbnailProvider: payload.thumbnailProvider, droppedCount: payload.droppedCount,
                    accessState: payload.accessState
                )
            }
            .fullScreenCover(isPresented: $showsDenied) {
                ImportPermissionDeniedView()
            }
    }

    /// merge-review R1 M6：`.onChange(of: pickerSelection)` 在 picker 正在 dismiss 的同一個
    /// 更新週期內若直接觸發下一個 presentation，UIKit 對「前一個 presentation 尚未 dismiss
    /// 完成就 present 下一個」會直接丟掉這次 present（實機三次快速選取複測，見 handoff）。
    /// `.fullScreenCover(item:)` 本身只在 `organizePayload` 從 nil 變成非 nil 時觸發一次
    /// present，`.photosPicker` 的 dismiss 與這次 present 走的是兩個不同的 `@State`（
    /// `showsPicker` vs `organizePayload`），不會互搶同一個 presentation slot；`showsPicker`
    /// 由系統在 picker 真正 dismiss 完成時才撥回 `false`，這裡不需要再手動等它。
    @MainActor
    private func presentOrganize(with result: PhotoLibraryAccessService.PickedAssetsResult) {
        organizePayload = OrganizePayload(
            pickedAssets: result.pickedAssets,
            thumbnailProvider: result.assetsByID.isEmpty ? nil : ImportThumbnailProvider(assetsByID: result.assetsByID),
            droppedCount: result.droppedCount, accessState: accessState
        )
    }

    @MainActor
    private func requestAccessAndProceed() async {
        let state = await PhotoLibraryAccessService.requestAccess()
        accessState = state
        if state == .denied {
            showsDenied = true
        } else {
            showsPicker = true
        }
    }
}

/// `.fullScreenCover(item:)` 用的整批資料——見 `ImportBatchFlowModifier.body(content:)`
/// 文件註解「stale-closure-capture」的修法。
private struct OrganizePayload: Identifiable {
    let id = UUID()
    let pickedAssets: [ImportDateGrouping.PickedAsset]
    let thumbnailProvider: ImportThumbnailProvider?
    let droppedCount: Int
    let accessState: PhotoLibraryAccessState
}

extension View {
    /// `isActive`：呼叫端按鈕觸發用的 binding（見型別文件註解）。`entrySource`：LS-303 R2
    /// M2 裁決——決定整理頁每群相簿預設值。
    func importBatchFlow(
        isActive: Binding<Bool>, childrenStore: ChildrenStore, albumsStore: AlbumsStore,
        entrySource: ImportEntrySource
    ) -> some View {
        modifier(ImportBatchFlowModifier(
            isActive: isActive, childrenStore: childrenStore, albumsStore: albumsStore, entrySource: entrySource
        ))
    }
}
