import PhotosUI
import SwiftUI

/// 相機膠卷批次匯入「選取→整理」的入口串接（LS-303 範圍 1／4）——把「請求相片庫授權
/// →（`.denied` 就攔在 06b／否則開 PHPicker）→ 依 `itemIdentifier` 反查 EXIF 分組
/// → 開整理頁」這串流程包成一個 `ViewModifier`，讓 `AlbumDetailView`／`TimelineView`
/// 兩個呼叫端只需要各自加一顆觸發鈕＋掛這個 modifier，不用各自重寫一次這串邏輯。
///
/// `isActive` 由呼叫端的按鈕觸發（設為 `true`）；本 modifier 自己在流程跑完（或使用者取消）
/// 後把它撥回 `false`，呼叫端不需要自己管理中繼狀態。
struct ImportBatchFlowModifier: ViewModifier {
    @Binding var isActive: Bool
    let childrenStore: ChildrenStore
    let albumsStore: AlbumsStore
    var uploadCoordinator: ImportUploadCoordinator = NoOpImportUploadCoordinator()

    @State private var accessState: PhotoLibraryAccessState = .authorized
    @State private var showsPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showsOrganize = false
    @State private var showsDenied = false
    @State private var pickedAssets: [ImportDateGrouping.PickedAsset] = []

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
                pickedAssets = PhotoLibraryAccessService.pickedAssets(for: items)
                pickerSelection = []
                showsOrganize = true
            }
            .fullScreenCover(isPresented: $showsOrganize) {
                ImportOrganizeView(
                    childrenStore: childrenStore, albumsStore: albumsStore, uploadCoordinator: uploadCoordinator,
                    pickedAssets: pickedAssets, accessState: accessState
                )
            }
            .fullScreenCover(isPresented: $showsDenied) {
                ImportPermissionDeniedView()
            }
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

extension View {
    /// `isActive`：呼叫端按鈕觸發用的 binding（見型別文件註解）。
    func importBatchFlow(
        isActive: Binding<Bool>, childrenStore: ChildrenStore, albumsStore: AlbumsStore
    ) -> some View {
        modifier(ImportBatchFlowModifier(isActive: isActive, childrenStore: childrenStore, albumsStore: albumsStore))
    }
}
