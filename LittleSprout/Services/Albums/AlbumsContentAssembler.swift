import Foundation

/// 把一頁 `AlbumListingRow`（`albums` 表直接讀出、已內嵌張數與封面 fallback 的一頁，見該型別
/// 文件註解）組裝成 `[AlbumSummary]`（封面已簽名 URL、寶貝標記 id）——同
/// `TimelineContentAssembler` 的角色，只是這裡沒有 `get_family_timeline` 指標可以先分組，
/// 直接對一頁相簿 id 批次查詢。
///
/// merge-review R1 M1：張數不再由這裡對 `album_media` 分組計數（`AlbumListingRow.photoCount`
/// 已經是 PostgREST aggregate 算好的值），這裡只剩兩件事——寶貝標記 id、封面簽名 URL。
enum AlbumsContentAssembler {
    static func assemble(
        rows: [AlbumListingRow], apiClient: AlbumsAPIClient
    ) async throws -> [AlbumSummary] {
        guard !rows.isEmpty else { return [] }
        let ids = rows.map(\.id)

        // 兩支批次查詢彼此不依賴（都只吃 `ids`），平行發出省 RTT——同
        // `TimelineContentAssembler.fetchDiaryContents` m5 的既有理由。封面簽名 URL 依賴
        // `fetchMedia` 的結果（要先知道 `cover_media_id` 指到哪些 media id 的
        // `thumb_path`／`storage_path`），所以簽名放在 `coverMediaTask` 完成之後才發。
        async let childLinksTask = apiClient.fetchAlbumChildren(albumIds: ids)
        let explicitCoverIds = Array(Set(rows.compactMap(\.coverMediaId)))
        async let coverMediaTask: [MediaRow] = explicitCoverIds.isEmpty
            ? [] : apiClient.fetchMedia(ids: explicitCoverIds)
        let (childLinks, coverMediaRows) = try await (childLinksTask, coverMediaTask)

        // `MediaRow.storagePath` 非 optional（每一列一定有原始檔路徑），這裡的顯示路徑因此
        // 保證非 nil，用非 optional 字典——避免跟下面 fallback 分支（兩個欄位皆 optional）
        // 混在一起變成 `[UUID: String?]` 雙層 optional，`??` 疊 `flatMap` 不會自動壓平。
        let explicitCoverPathById: [UUID: String] = Dictionary(uniqueKeysWithValues: coverMediaRows.map { mediaRow in
            (mediaRow.id, mediaRow.thumbPath ?? mediaRow.storagePath)
        })
        let childIdsByAlbum = Dictionary(grouping: childLinks, by: \.albumId)
            .mapValues { links in links.map(\.childId) }

        // 每本相簿的顯示路徑：`cover_media_id` 指到的 media 列（`explicitCoverPathById`）優先；
        // 否則退回 `AlbumListingRow` 內嵌的最新一筆 album_media（merge-review R1 M3，票文
        // Scope 1 原意）；相簿沒有任何照片時兩者皆無，`nil`。
        let displayPathByAlbum: [UUID: String] = rows.reduce(into: [:]) { paths, row in
            paths[row.id] = row.coverMediaId.flatMap { explicitCoverPathById[$0] }
                ?? displayPath(thumbPath: row.latestMediaThumbPath, storagePath: row.latestMediaStoragePath)
        }
        let signed = try await signedURLs(forPaths: Array(Set(displayPathByAlbum.values)), apiClient: apiClient)

        return rows.map { row in
            AlbumSummary(
                id: row.id, title: row.title, photoCount: row.photoCount,
                cover: displayPathByAlbum[row.id].flatMap { signed[$0] },
                childIds: childIdsByAlbum[row.id] ?? [], createdAt: row.createdAt
            )
        }
    }

    /// 列表情境要簽的路徑——`thumb_path` 優先、`nil` 時退回 `storage_path`（過渡期既有列、
    /// 縮圖產生失敗的列，或根本沒有 `thumb_path` 這一欄可選的情境），見 docs/API.md §6
    /// 「簽名 URL 與 egress 防線」。`storagePath` 為 `nil` 時（相簿沒有任何照片、也沒有指定
    /// 封面）整條回傳 `nil`，呼叫端顯示占位圖。
    private static func displayPath(thumbPath: String?, storagePath: String?) -> String? {
        thumbPath ?? storagePath
    }

    private static func signedURLs(
        forPaths paths: [String], apiClient: AlbumsAPIClient
    ) async throws -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        return try await apiClient.signedURLs(forStoragePaths: paths)
    }
}
