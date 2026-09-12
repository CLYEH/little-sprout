import Foundation

/// 把一頁 `AlbumListingRow`（`album_summaries` view 直接讀出，已套用呼叫者 RLS 算好張數與
/// 封面 fallback 路徑的一頁，見該型別文件註解）組裝成 `[AlbumSummary]`（封面已簽名 URL、寶貝
/// 標記 id）——同 `TimelineContentAssembler` 的角色，只是這裡沒有 `get_family_timeline`
/// 指標可以先分組，直接對一頁相簿 id 批次查詢。
///
/// LS-203：張數與封面優先序改讀 `album_summaries` 的彙總欄，這裡不再呼叫 `fetchMedia` 反查
/// `cover_media_id`（LS-165 R1 M3 的做法）——view 的 `cover_thumb_path`／`cover_storage_path`
/// 已經是「`cover_media_id` 指到的那筆 media，套用呼叫者 RLS 之後」的路徑，可見性判準與
/// 縮圖／原圖優先序都在 SQL 層做完，不需要再發第二支查詢。這裡只剩兩件事——寶貝標記 id、
/// 封面（四段 fallback）已簽名 URL。
enum AlbumsContentAssembler {
    static func assemble(
        rows: [AlbumListingRow], apiClient: AlbumsAPIClient
    ) async throws -> [AlbumSummary] {
        guard !rows.isEmpty else { return [] }
        let ids = rows.map(\.id)
        let displayPathByAlbum: [UUID: String] = rows.reduce(into: [:]) { paths, row in
            paths[row.id] = displayPath(for: row)
        }

        // merge-review R2 minor-1：兩者互不相依（`fetchAlbumChildren` 只吃 `ids`，
        // `signedURLs` 只吃 `displayPathByAlbum`，`fetchMedia` 反查已隨 LS-203 拿掉），平行
        // 發出省一個 RTT——同 `TimelineContentAssembler.fetchDiaryContents` m5 的既有理由。
        async let childLinksTask = apiClient.fetchAlbumChildren(albumIds: ids)
        async let signedTask = signedURLs(forPaths: Array(Set(displayPathByAlbum.values)), apiClient: apiClient)
        let (childLinks, signed) = try await (childLinksTask, signedTask)

        let childIdsByAlbum = Dictionary(grouping: childLinks, by: \.albumId)
            .mapValues { links in links.map(\.childId) }

        return rows.map { row in
            AlbumSummary(
                id: row.id, title: row.title, photoCount: row.photoCount,
                cover: displayPathByAlbum[row.id].flatMap { signed[$0] },
                childIds: childIdsByAlbum[row.id] ?? [], createdAt: row.createdAt,
                latestMediaId: row.latestMediaId
            )
        }
    }

    /// 封面優先序（票文 Scope 2，`album_summaries` 四個彙總欄）：`cover_thumb_path` →
    /// `cover_storage_path`（縮圖產生失敗的過渡列）→ `latest_thumb_path`（未指定封面，退回
    /// 可見範圍內最新一張）→ `latest_storage_path` → 全部皆無時 `nil`（灰底占位）。四段都
    /// 直接讀 `AlbumListingRow` 欄位，不需要另外查 `media` 表。
    private static func displayPath(for row: AlbumListingRow) -> String? {
        row.coverThumbPath ?? row.coverStoragePath ?? row.latestMediaThumbPath ?? row.latestMediaStoragePath
    }

    private static func signedURLs(
        forPaths paths: [String], apiClient: AlbumsAPIClient
    ) async throws -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        return try await apiClient.signedURLs(forStoragePaths: paths)
    }
}
