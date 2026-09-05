import SwiftUI

/// 相簿詳情（LS-166，尚未實作）——LS-165 只建立最小佔位，讓 `AlbumsView` 的
/// `NavigationLink(value:)`／`navigationDestination(for: AlbumRoute.self)` 路由先接通。
/// LS-166 只會替換這個檔案的內容，不會動 `AlbumRoute`（見該檔文件註解）或
/// `AlbumSummary`（`Services/Albums/AlbumsModels.swift`）。
///
/// 只帶 `albumID`：內容從 `albumsStore.albums` 依 id 查目前最新的一筆（同
/// `DiaryDetailView.diaryID` 的既有理由），避免推入當下捕捉到的舊資料在使用者停留期間過期。
struct AlbumDetailView: View {
    let albumID: UUID
    let albumsStore: AlbumsStore

    private var album: AlbumSummary? {
        albumsStore.albums.first { $0.id == albumID }
    }

    var body: some View {
        ContentUnavailableView(
            album?.title ?? "相簿",
            systemImage: "photo.stack",
            description: Text("相簿詳情尚未推出，敬請期待。")
        )
    }
}

#if DEBUG
#Preview {
    let store = AlbumsStore.preview()
    let albumID = UUID()
    store.seedForPreview(albums: [
        AlbumSummary(id: albumID, title: "2026 夏天的海邊", photoCount: 12, cover: nil, childIds: [], createdAt: Date())
    ])
    return NavigationStack {
        AlbumDetailView(albumID: albumID, albumsStore: store)
    }
}
#endif
