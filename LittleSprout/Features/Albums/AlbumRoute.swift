import Foundation

/// 相簿 tab 首頁的子路由（LS-165／LS-166 接縫）。只帶 id，同 `TimelineRoute`／
/// `ChildrenRoute` 的既有理由：目的地畫面（`AlbumDetailView`）從 `AlbumsStore.albums` 依 id
/// 查目前最新的一筆，避免推入當下捕捉到的舊資料在使用者停留期間過期。
///
/// 刻意獨立成檔案、不塞進 `AlbumsView.swift`（票文環境段要求）——LS-166（相簿詳情）只會替換
/// `AlbumDetailView.swift` 的內容，不需要改這個路由型別，兩張票的變更範圍在檔案層級就先切開。
enum AlbumRoute: Hashable {
    case detail(UUID)
}
