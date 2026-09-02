import Foundation

/// 把 `get_family_timeline` 的指標（`kind`／`ref_id`）組裝成完整內容（`TimelineEntry`）。
///
/// 刻意是一個**沒有 actor 隔離的自由 enum**，不是 `TimelineStore`（`@MainActor`）的方法：
/// docs/API.md `get_family_timeline` 文件明確要求三支批次查詢（diary／album／media）用
/// `withThrowingTaskGroup` 平行發出、不要序列 `await`——若這些方法掛在 `@MainActor` 類別上，
/// 每次呼叫都會先跳回 MainActor 才能執行，實質上仍是序列。這裡讓三支查詢各自在背景
/// task 裡直接呼叫 `apiClient`（`Sendable` 協定），互不等待對方，只有最後收集結果那段
/// （`for try await batch in group`）在呼叫端所在的 context 執行。
enum TimelineContentAssembler {
    private enum ContentBatch {
        case diaries([UUID: DiaryContent])
        case albums([UUID: AlbumContent])
        case media([UUID: MediaContent])
    }

    /// 三支批次查詢的結果——獨立命名型別而不是 tuple（SwiftLint `large_tuple` 只准 2 個
    /// 成員，這裡有 3 個）。
    private struct ContentMaps {
        var diaries: [UUID: DiaryContent] = [:]
        var albums: [UUID: AlbumContent] = [:]
        var media: [UUID: MediaContent] = [:]
    }

    static func assemble(
        pointers: [TimelineFeedPointer], apiClient: TimelineAPIClient
    ) async throws -> [TimelineEntry] {
        guard !pointers.isEmpty else { return [] }
        let byKind = Dictionary(grouping: pointers, by: \.kind)
        let maps = try await fetchContentMaps(byKind: byKind, apiClient: apiClient)
        return buildEntries(pointers: pointers, maps: maps)
    }

    /// 三支批次查詢（diary／album／media）用 `withThrowingTaskGroup` 平行發出，見
    /// docs/API.md `get_family_timeline` 文件與本檔頂端註解。
    private static func fetchContentMaps(
        byKind: [FeedKind: [TimelineFeedPointer]], apiClient: TimelineAPIClient
    ) async throws -> ContentMaps {
        var maps = ContentMaps()
        try await withThrowingTaskGroup(of: ContentBatch.self) { group in
            if let ids = byKind[.diary]?.map(\.refId) {
                group.addTask { .diaries(try await fetchDiaryContents(ids: ids, apiClient: apiClient)) }
            }
            if let ids = byKind[.album]?.map(\.refId) {
                group.addTask { .albums(try await fetchAlbumContents(ids: ids, apiClient: apiClient)) }
            }
            if let ids = byKind[.media]?.map(\.refId) {
                group.addTask { .media(try await fetchMediaContents(ids: ids, apiClient: apiClient)) }
            }
            // 收集端序列（同一個 for-await），但三支查詢本身已經平行發出——這裡只是
            // 把各自的結果寫回各自對應的字典，不是重新序列化查詢本身。
            for try await batch in group {
                switch batch {
                case .diaries(let value): maps.diaries = value
                case .albums(let value): maps.albums = value
                case .media(let value): maps.media = value
                }
            }
        }
        return maps
    }

    private static func buildEntries(pointers: [TimelineFeedPointer], maps: ContentMaps) -> [TimelineEntry] {
        pointers.map { pointer in
            let content: TimelineEntry.Content?
            switch pointer.kind {
            case .diary: content = maps.diaries[pointer.refId].map(TimelineEntry.Content.diary)
            case .album: content = maps.albums[pointer.refId].map(TimelineEntry.Content.album)
            case .media: content = maps.media[pointer.refId].map(TimelineEntry.Content.media)
            }
            return TimelineEntry(
                kind: pointer.kind, refId: pointer.refId, occurredAt: pointer.occurredAt,
                childIds: pointer.childIds, content: content
            )
        }
    }

    /// 日記詳情的瀑布流用——`diaryID` 這篇日記**全部**附照（依 `sort_order` 排序），不是
    /// 時間軸卡片只露的前 3 張。
    static func fetchDiaryPhotos(diaryID: UUID, apiClient: TimelineAPIClient) async throws -> [MediaContent] {
        let links = try await apiClient.fetchDiaryMediaLinks(diaryIds: [diaryID])
        let sortedLinks = links.sorted { $0.sortOrder < $1.sortOrder }
        let mediaIds = sortedLinks.map(\.mediaId)
        guard !mediaIds.isEmpty else { return [] }
        let rows = try await apiClient.fetchMedia(ids: mediaIds)
        let signed = try await signedURLs(for: rows, apiClient: apiClient)
        let rowById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return sortedLinks.compactMap { link in
            guard let row = rowById[link.mediaId] else { return nil }
            return MediaContent(
                id: row.id, type: row.type, width: row.width, height: row.height,
                signedURL: signed[row.storagePath]
            )
        }
    }

    // MARK: - 逐 kind 批次查詢

    /// merge-review R1 M3：只抓每篇日記前 3 張（sort_order 排序）的完整 media 列＋簽名 URL
    /// ——時間軸卡片本來就只露前 3 張（`DiaryCardView`），不需要為了算「還有 N 張」的總數
    /// 把整頁所有日記的**全部**附照都抓齊再簽名。一頁 20 篇日記、每篇上限 20 張附照時，
    /// 舊寫法會產生上百個 media id 塞進 `.in()` 的 GET query string，超過 proxy 的請求長度
    /// 上限會讓整頁組裝直接失敗。`diary_media` 連結表本身很輕量（僅 3 欄），全部抓來分組、
    /// 只在其中挑前 3 名去查／簽真正的 `media` 列＋Storage URL；`totalPhotoCount` 直接用
    /// 連結表的列數，不依賴抓到多少張 `media` 列。
    private static func fetchDiaryContents(
        ids: [UUID], apiClient: TimelineAPIClient
    ) async throws -> [UUID: DiaryContent] {
        // m5：兩者互不依賴（都只吃 `ids`），平行發出省一個 RTT。
        async let diariesTask = apiClient.fetchDiaries(ids: ids)
        async let linksTask = apiClient.fetchDiaryMediaLinks(diaryIds: ids)
        let (diaries, links) = try await (diariesTask, linksTask)

        let linksByDiary = Dictionary(grouping: links, by: \.diaryId)
        var previewLinksByDiary: [UUID: [DiaryMediaLinkRow]] = [:]
        previewLinksByDiary.reserveCapacity(linksByDiary.count)
        for (diaryId, diaryLinks) in linksByDiary {
            previewLinksByDiary[diaryId] = Array(diaryLinks.sorted { $0.sortOrder < $1.sortOrder }.prefix(3))
        }
        let previewMediaIds = Array(Set(previewLinksByDiary.values.flatMap { $0.map(\.mediaId) }))
        let mediaRows = previewMediaIds.isEmpty ? [] : try await apiClient.fetchMedia(ids: previewMediaIds)
        let signed = try await signedURLs(for: mediaRows, apiClient: apiClient)
        let mediaById = Dictionary(uniqueKeysWithValues: mediaRows.map { ($0.id, $0) })

        var result: [UUID: DiaryContent] = [:]
        for diary in diaries {
            let previewLinks = previewLinksByDiary[diary.id] ?? []
            let photos: [MediaContent] = previewLinks.compactMap { link in
                guard let row = mediaById[link.mediaId] else { return nil }
                return MediaContent(
                    id: row.id, type: row.type, width: row.width, height: row.height,
                    signedURL: signed[row.storagePath]
                )
            }
            result[diary.id] = DiaryContent(
                body: diary.body, entryDate: diary.entryDate,
                previewPhotos: photos, totalPhotoCount: linksByDiary[diary.id]?.count ?? 0
            )
        }
        return result
    }

    private static func fetchAlbumContents(
        ids: [UUID], apiClient: TimelineAPIClient
    ) async throws -> [UUID: AlbumContent] {
        let albums = try await apiClient.fetchAlbums(ids: ids)
        let coverIds = Array(Set(albums.compactMap(\.coverMediaId)))
        let mediaRows = coverIds.isEmpty ? [] : try await apiClient.fetchMedia(ids: coverIds)
        let signed = try await signedURLs(for: mediaRows, apiClient: apiClient)
        let mediaById = Dictionary(uniqueKeysWithValues: mediaRows.map { ($0.id, $0) })

        var result: [UUID: AlbumContent] = [:]
        for album in albums {
            let cover: MediaContent? = album.coverMediaId.flatMap { mediaById[$0] }.map { row in
                MediaContent(
                    id: row.id, type: row.type, width: row.width, height: row.height,
                    signedURL: signed[row.storagePath]
                )
            }
            result[album.id] = AlbumContent(title: album.title, cover: cover)
        }
        return result
    }

    private static func fetchMediaContents(
        ids: [UUID], apiClient: TimelineAPIClient
    ) async throws -> [UUID: MediaContent] {
        let rows = try await apiClient.fetchMedia(ids: ids)
        let signed = try await signedURLs(for: rows, apiClient: apiClient)
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.id, MediaContent(
                id: row.id, type: row.type, width: row.width, height: row.height,
                signedURL: signed[row.storagePath]
            ))
        })
    }

    private static func signedURLs(
        for mediaRows: [MediaRow], apiClient: TimelineAPIClient
    ) async throws -> [String: URL] {
        guard !mediaRows.isEmpty else { return [:] }
        return try await apiClient.signedURLs(forStoragePaths: mediaRows.map(\.storagePath))
    }
}
