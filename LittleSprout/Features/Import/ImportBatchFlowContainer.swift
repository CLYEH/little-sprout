import SwiftUI

/// LS-304：批次匯入「選取→整理→上傳→摘要」整條流程的容器——`ImportBatchFlowModifier` 唯一的
/// `.fullScreenCover(item:)` 內容，取代原本直接放 `ImportOrganizeView`。
///
/// **為什麼用內部狀態切換，不用循序 `.fullScreenCover`／`.sheet`，也不用 `NavigationStack`**：
/// LS-251 Notes「與 LS-142 佇列的邊界」明白把 01→04→05 描述成「獨立導覽堆疊」，但 04／05
/// 都沒有系統返回鍵、沒有「往回滑」語意，只有「取消匯入」／「在背景繼續」／「完成」這幾顆
/// 明確動作鈕（見 Notes「畫面級屬性」04／04b／05 三列釘底動作帶欄）——`NavigationStack` 的
/// push／pop 語意用不到，反而要多處理返回手勢／系統返回鍵要不要出現的問題。連續觸發兩個
/// 獨立的 `.fullScreenCover`／`.sheet`（先 dismiss 一個再 present 下一個）在這個檔案家族已經
/// 有兩次實測踩雷記錄——`ImportBatchFlowModifier` 檔頭「stale-closure-capture」與
/// merge-review R1 M6「前一個 presentation 尚未 dismiss 完成就 present 下一個會被系統丟掉」
/// ——都是「同一個 run loop 裡連續觸發兩個獨立 presentation」這一類問題。改成單一
/// `.fullScreenCover` 底下用一個 `@State` enum 切換內容（同 `AlbumDetailView.body` 的
/// `if let detailStore {…} else {…}` 既有慣例，只是這裡是三態不是兩態），從根本避開這整類
/// 競態：整條流程從頭到尾只有「進 cover」與「離開 cover」兩次真正的 presentation 事件。
struct ImportBatchFlowContainer: View {
    let childrenStore: ChildrenStore
    let albumsStore: AlbumsStore
    let uploadCoordinator: ImportUploadCoordinator
    let entrySource: ImportEntrySource
    let pickedAssets: [ImportDateGrouping.PickedAsset]
    let thumbnailProvider: ImportThumbnailProvider?
    let droppedCount: Int
    let accessState: PhotoLibraryAccessState

    @Environment(\.dismiss) private var dismiss
    @State private var route: Route = .organize

    private enum Route {
        case organize
        case progress(ImportBatchSession)
        case summary(ImportBatchSession)
    }

    var body: some View {
        switch route {
        case .organize:
            ImportOrganizeView(
                childrenStore: childrenStore, albumsStore: albumsStore, uploadCoordinator: uploadCoordinator,
                pickedAssets: pickedAssets, entrySource: entrySource, thumbnailProvider: thumbnailProvider,
                droppedCount: droppedCount, accessState: accessState,
                onImportStarted: { session in route = .progress(session) }
            )
        case .progress(let session):
            // `sharedUploadQueueStoreInstance` 在這個 route 出現前必定已經被
            // `AlbumImportUploadCoordinator.startImport(plan:)` 建立過（見該檔文件註解）——
            // `nil` 只可能發生在型別要求的保底 `NoOpImportUploadCoordinator` 被誤用時，理論上
            // 不該發生（同 `AlbumDetailView.importUploadCoordinator` 既有的保底註解）；防禦性
            // 退回上一頁而不是卡在空白畫面。
            if let store = albumsStore.sharedUploadQueueStoreInstance {
                Import04ProgressView(
                    session: session, store: store,
                    onLeaveInBackground: { dismiss() },
                    onAllItemsFinished: { route = .summary(session) },
                    onCancelledImport: { dismiss() }
                )
            } else {
                Color.clear.onAppear { dismiss() }
            }
        case .summary(let session):
            if let store = albumsStore.sharedUploadQueueStoreInstance {
                Import05SummaryView(session: session, store: store, onDone: { dismiss() })
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
    }
}
