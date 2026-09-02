import Foundation

/// `get_family_timeline` 回傳的 `kind` 欄——`public.feed_kind` enum，PostgREST 序列化成
/// JSON 字串（見 `docs/API.md` §4 `get_family_timeline`）。
enum FeedKind: String, Decodable, Sendable, Hashable {
    case diary, album, media
}

enum MediaType: String, Decodable, Sendable, Equatable {
    case photo, video
}

/// `get_family_timeline` 一列——只是指標（`kind`／`ref_id`），不是完整內容；完整內容依
/// `kind` 分組後各發一支批次查詢（見 `TimelineContentAssembler`）。
struct TimelineFeedPointer: Decodable, Sendable, Equatable {
    let kind: FeedKind
    let refId: UUID
    let occurredAt: Date
    let childIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case kind
        case refId = "ref_id"
        case occurredAt = "occurred_at"
        case childIds = "child_ids"
    }
}

/// `get_family_timeline` keyset 分頁游標——`(occurred_at, ref_id)` 一對，只傳其中一個
/// （另一個留 `NULL`）會拿到 `LS022`（見 docs/API.md）。刻意合成單一型別、不拆成兩個
/// 各自 optional 的參數，讓「兩者要嘛都傳、要嘛都不傳」在型別層面就不可能違反。
struct TimelineCursor: Equatable, Sendable {
    let occurredAt: Date
    let refId: UUID
}

// MARK: - 逐表 wire row（`.from(...)` 直接讀，見 docs/API.md §2）

/// `diaries` 表可讀欄位子集。
struct DiaryRow: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let body: String
    let entryDate: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, body
        case entryDate = "entry_date"
        case createdAt = "created_at"
    }

    /// `entry_date` 是 Postgres `date`（無時區）——同 `Child.birthday` 的理由，見
    /// `BirthdayFormat` 文件註解，這裡沿用同一支解析器（LS-126 票文 Scope 5：
    /// `ageDescription` 沿用 `BirthdayFormat`，日期解析同一套邏輯沒有理由另開一份）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        let entryDateString = try container.decode(String.self, forKey: .entryDate)
        guard let entryDate = BirthdayFormat.date(fromWireString: entryDateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .entryDate, in: container, debugDescription: "無法解析 entry_date：\(entryDateString)"
            )
        }
        self.entryDate = entryDate
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    init(id: UUID, body: String, entryDate: Date, createdAt: Date) {
        self.id = id
        self.body = body
        self.entryDate = entryDate
        self.createdAt = createdAt
    }
}

/// `albums` 表可讀欄位子集。
struct AlbumRow: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let coverMediaId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, title
        case coverMediaId = "cover_media_id"
    }
}

/// `media` 表可讀欄位子集。
struct MediaRow: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let storagePath: String
    let type: MediaType
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case type, width, height
    }
}

/// `diary_media` 連結表一列（`diary_id`／`media_id`／`sort_order`）。
struct DiaryMediaLinkRow: Decodable, Sendable, Equatable {
    let diaryId: UUID
    let mediaId: UUID
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case diaryId = "diary_id"
        case mediaId = "media_id"
        case sortOrder = "sort_order"
    }
}

// MARK: - 組裝後的顯示模型（`TimelineContentAssembler` 產出，供 UI 直接使用）

/// 已拿到簽名 URL 的一張照片／影片——時間軸「照片卡」／日記附照／瀑布流照片牆共用。
struct MediaContent: Equatable, Sendable, Identifiable {
    let id: UUID
    let type: MediaType
    let width: Int
    let height: Int
    /// 簽名失敗（見 `TimelineAPIClient.signedURLs`）時為 nil——呼叫端顯示占位圖，
    /// 不讓整頁因為單一檔案簽名失敗而整批失敗。
    let signedURL: URL?

    /// 寬高比（寬／高），用於瀑布流等比縮放；`width`／`height` 皆為正整數
    /// （`media` 表 `CHECK (width > 0)`／`CHECK (height > 0)`，不會是 0）。
    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }
}

struct DiaryContent: Equatable, Sendable {
    let body: String
    let entryDate: Date
    /// 依 `sort_order` 排序後的前 3 張——時間軸日記卡「附照只露 3 張」。
    let previewPhotos: [MediaContent]
    /// 這篇日記附照的總數（不受上面只取前 3 張影響）——「還有 N 張」＝
    /// `totalPhotoCount - previewPhotos.count`。
    let totalPhotoCount: Int
}

struct AlbumContent: Equatable, Sendable {
    let title: String
    let cover: MediaContent?
}

/// 一則時間軸項目：`get_family_timeline` 的指標欄位＋依 `kind` 組裝出的完整內容。
struct TimelineEntry: Equatable, Sendable, Identifiable {
    enum Content: Equatable, Sendable {
        case diary(DiaryContent)
        case album(AlbumContent)
        case media(MediaContent)
    }

    let kind: FeedKind
    let refId: UUID
    let occurredAt: Date
    let childIds: [UUID]
    /// 該筆內容組裝失敗（例如批次查詢那一支剛好失敗）時為 nil——呼叫端跳過渲染這一列，
    /// 不讓整頁因單一項目失敗而整批消失（見 `TimelineContentAssembler`）。
    let content: Content?

    /// 同時涵蓋三種 kind 的複合鍵——`ref_id` 理論上跨表不會相撞，但 `kind` 一起入 id
    /// 讓「同一頁三種 kind 各查各的表」這件事在型別層面就不可能因為 UUID 巧合碰撞。
    var id: String { "\(kind.rawValue)_\(refId.uuidString)" }
}
