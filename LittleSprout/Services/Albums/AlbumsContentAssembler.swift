import Foundation

/// 把一頁 `AlbumListingRow`（`albums` 表直接讀出的一頁）組裝成 `[AlbumSummary]`（封面已簽名
/// URL、張數、寶貝標記 id）——同 `TimelineContentAssembler` 的角色，只是這裡沒有
/// `get_family_timeline` 指標可以先分組，直接對一頁相簿 id 批次查詢。
enum AlbumsContentAssembler {
    static func assemble(
        rows: [AlbumListingRow], apiClient: AlbumsAPIClient
    ) async throws -> [AlbumSummary] {
        guard !rows.isEmpty else { return [] }
        let ids = rows.map(\.id)

        // 三支批次查詢彼此不依賴（都只吃 `ids`），平行發出省 RTT——同
        // `TimelineContentAssembler.fetchDiaryContents` m5 的既有理由。封面簽名 URL 依賴
        // `fetchMedia` 的結果（要先知道 `cover_media_id` 指到哪些 media id），所以簽名放在
        // `mediaTask` 完成之後才發。
        async let mediaLinksTask = apiClient.fetchAlbumMediaLinks(albumIds: ids)
        async let childLinksTask = apiClient.fetchAlbumChildren(albumIds: ids)
        let coverIds = Array(Set(rows.compactMap(\.coverMediaId)))
        async let coverMediaTask: [MediaRow] = coverIds.isEmpty ? [] : apiClient.fetchMedia(ids: coverIds)
        let (mediaLinks, childLinks, coverMediaRows) = try await (mediaLinksTask, childLinksTask, coverMediaTask)

        let signed = try await signedURLs(for: coverMediaRows, apiClient: apiClient)
        let coverById = Dictionary(uniqueKeysWithValues: coverMediaRows.map { ($0.id, $0) })
        let photoCountByAlbum = mediaLinks.reduce(into: [UUID: Int]()) { counts, link in
            counts[link.albumId, default: 0] += 1
        }
        let childIdsByAlbum = Dictionary(grouping: childLinks, by: \.albumId)
            .mapValues { links in links.map(\.childId) }

        return rows.map { row in
            let cover: MediaContent? = row.coverMediaId.flatMap { coverById[$0] }.map { mediaRow in
                MediaContent(
                    id: mediaRow.id, type: mediaRow.type, width: mediaRow.width, height: mediaRow.height,
                    thumbWidth: mediaRow.thumbWidth, thumbHeight: mediaRow.thumbHeight,
                    storagePath: mediaRow.storagePath, isThumbnail: mediaRow.thumbPath != nil,
                    signedURL: signed[displayPath(mediaRow)], durationSeconds: mediaRow.durationSeconds
                )
            }
            return AlbumSummary(
                id: row.id, title: row.title, photoCount: photoCountByAlbum[row.id] ?? 0, cover: cover,
                childIds: childIdsByAlbum[row.id] ?? [], createdAt: row.createdAt
            )
        }
    }

    /// LS-142 Handoff Notes `xKN9q`：封面判定規則票文寫「最新縮圖」，但 `albums` 表實際有
    /// `cover_media_id` 欄位（可由使用者指定）。本輪（同 `TimelineContentAssembler.
    /// fetchAlbumContents` 既有行為，時間軸相簿卡就是這樣做）只用 `cover_media_id`，未指定
    /// 時封面為 `nil`（呼叫端顯示占位圖）——刻意不實作「`cover_media_id` 為 null 時取
    /// `album_media` 最新一筆」的 fallback：那份 fallback 邏輯本身要先定義「最新」依 media
    /// 的哪個欄位排序（`album_media` 本身沒有時間戳），且與既有時間軸相簿卡行為不一致會造成
    /// 同一本相簿在兩個畫面顯示不同封面。Notes 原文承認「兩種情況畫面本身視覺相同不需要
    /// 另外設計」，這裡選擇跟既有生產路徑一致的最簡實作，見 handoff「未完成」欄。
    private static func displayPath(_ row: MediaRow) -> String {
        row.thumbPath ?? row.storagePath
    }

    private static func signedURLs(
        for mediaRows: [MediaRow], apiClient: AlbumsAPIClient
    ) async throws -> [String: URL] {
        guard !mediaRows.isEmpty else { return [:] }
        return try await apiClient.signedURLs(forStoragePaths: mediaRows.map(displayPath))
    }
}
