import Foundation

/// 相簿 tab 首頁（LS-165，依 LS-142 稿）keyset 分頁游標——`(created_at, id)` 一對，同
/// `TimelineCursor` 的理由（見該檔文件註解）：只用 `created_at` 分頁在同一時間戳多筆相簿時
/// 會漏項／跳項（`albums_family_created_idx` 索引註解已點名這個風險），合成單一型別讓「兩者
/// 要嘛都有、要嘛都沒有」在型別層面就不可能違反。
struct AlbumsCursor: Equatable, Sendable {
    let createdAt: Date
    let id: UUID
}

/// `albums` 表可讀欄位子集，供相簿列表使用（`docs/API.md` §2 `albums` 列：直接 `.from()`
/// 讀取，沒有專屬的 `list_albums` RPC）。比 `TimelineModels.AlbumRow` 多帶 `createdAt`——
/// 那支只服務時間軸單筆相簿卡組裝，不需要分頁游標；這裡需要。
///
/// merge-review R1 M1：張數與封面 fallback 改成 PostgREST 內嵌查詢，不再整頁抓
/// `album_media` 在 client 端數（`PGRST_DB_MAX_ROWS=1000` 會截斷、回傳順序不保證、白付
/// payload）——本機已實測 `db-aggregates-enabled` 可用（`GET /rest/v1/albums?select=
/// id,title,album_media(count)` 回 `[{"count":n}]`，見 `SupabaseAlbumsAPIClient.fetchAlbums`
/// 文件註解的完整查詢字串）：
///   - `photoCount` 來自內嵌 `album_media(count)`（PostgREST aggregate，一個元素的陣列）。
///     merge-review R2 m3：這個數字數的是 `album_media` 連結列本身，包含使用者透過 RLS
///     看不到的 media（已軟刪、非自己上傳；或 LS-155 刪帳號後 `uploaded_by` 被清成
///     `NULL`）——本機實測過幾種「inner join 後計數」的 select 寫法（`album_media(media!
///     inner(id),count)`／`album_media!inner(media!inner(count))` 等），要嘛拿到
///     `42803`（count 與其他欄位混用要求 GROUP BY），要嘛拿到的是「每個 album_media 各自
///     一個 count」而不是單一總數，PostgREST 目前的 embed+aggregate 語法組合做不到「只數
///     inner join 命中的列」這種依賴巢狀可見性的計數。維持連結列計數（跟被裁定前的 R1 行為
///     一致），口徑差異記錄在這裡與 docs/API.md `albums` 段，未來若要精確排除不可見照片需要
///     後端另開一個 view 或 RPC。
///   - `latestMediaThumbPath`／`latestMediaStoragePath` 來自內嵌別名 `latest:album_media(
///     media!inner(thumb_path, storage_path, created_at))`，依 `media(created_at)` 排序（不是
///     `album_media` 自己的欄位——那張連結表沒有 `created_at`，只有 `album_id`／`media_id`／
///     `family_id`／`sort_order`）取最新一筆，供 M3 封面 fallback 用（`cover_media_id` 未
///     指定時退回這裡）；一本相簿沒有任何「看得見」的照片時（不論是真的 0 張，還是唯一的
///     照片被 RLS 濾掉）這個陣列是空的，兩個欄位皆為 `nil`——`media!inner` 保證看不見的
///     media 不會混進來（merge-review R2 B1，見 `SupabaseAlbumsAPIClient.listSelect`
///     文件註解的完整踩雷記錄），`LatestAlbumMediaEntry.media` 仍宣告成 optional 當第二層
///     防守，不只依賴這一個查詢寫法保證解碼不會失敗。
struct AlbumListingRow: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let coverMediaId: UUID?
    let createdAt: Date
    let photoCount: Int
    let latestMediaThumbPath: String?
    let latestMediaStoragePath: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case coverMediaId = "cover_media_id"
        case createdAt = "created_at"
        case albumMedia = "album_media"
        case latest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        coverMediaId = try container.decodeIfPresent(UUID.self, forKey: .coverMediaId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let counts = try container.decode([AlbumMediaCountEntry].self, forKey: .albumMedia)
        photoCount = counts.first?.count ?? 0
        let latestEntries = try container.decodeIfPresent([LatestAlbumMediaEntry].self, forKey: .latest) ?? []
        // merge-review R2 B1 第二層防守：`media!inner` 已經在 SQL 層排除看不見的候選，理論上
        // 不會再出現 `{"media": null}`，但這裡仍用 `compactMap` 過濾、不假設查詢寫法永遠正確
        // ——寧可退回占位圖，不要因為單一連結列的巢狀 `media` 意外是 `null` 就讓整頁 throw。
        let visibleMedia = latestEntries.compactMap(\.media).first
        latestMediaThumbPath = visibleMedia?.thumbPath
        latestMediaStoragePath = visibleMedia?.storagePath
    }

    /// 供測試／`.preview()` 假資料組建——`init(from:)` 服務真正的 PostgREST 回應形狀
    /// （巢狀陣列），呼叫端不會手動組那種結構。
    init(
        id: UUID, title: String, coverMediaId: UUID?, createdAt: Date, photoCount: Int = 0,
        latestMediaThumbPath: String? = nil, latestMediaStoragePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.coverMediaId = coverMediaId
        self.createdAt = createdAt
        self.photoCount = photoCount
        self.latestMediaThumbPath = latestMediaThumbPath
        self.latestMediaStoragePath = latestMediaStoragePath
    }
}

/// `AlbumListingRow.init(from:)` 解 `album_media(count)` 內嵌陣列的單一元素形狀——不能嵌在
/// `AlbumListingRow` 裡面（跟 `LatestAlbumMediaEntry`／`LatestAlbumMedia` 加起來會超過
/// SwiftLint 巢狀型別上限），改成檔案層級的 `private` 型別，範圍仍只在這個檔案內。
private struct AlbumMediaCountEntry: Decodable {
    let count: Int
}

/// `AlbumListingRow.init(from:)` 解 `latest:album_media(media!inner(...))` 內嵌陣列的單一
/// 元素形狀。`media` 宣告成 optional——merge-review R2 B1：`media!inner` 已經在 SQL 層排除
/// 看不見的候選，理論上不會再收到 `{"media": null}`，這裡是不依賴單一查詢寫法的第二層防守
/// （真的收到 `null` 時 `AlbumListingRow.init(from:)` 用 `compactMap` 濾掉，不會整頁 throw）。
private struct LatestAlbumMediaEntry: Decodable {
    let media: LatestAlbumMedia?
}

private struct LatestAlbumMedia: Decodable {
    let thumbPath: String?
    let storagePath: String

    enum CodingKeys: String, CodingKey {
        case thumbPath = "thumb_path"
        case storagePath = "storage_path"
    }
}

/// `album_children` 連結表一列（LS-121）——相簿列表卡片署名列（`AlbumSignatureFormatter`）
/// 依此決定標記了哪些寶貝。
struct AlbumChildLinkRow: Decodable, Sendable, Equatable {
    let albumId: UUID
    let childId: UUID

    enum CodingKeys: String, CodingKey {
        case albumId = "album_id"
        case childId = "child_id"
    }
}

/// 相簿厚度分級（LS-142 Handoff Notes `EBlnw`）：扇影（Fan Ghost）片數是相簿「有多厚」唯一的
/// 視覺訊號，卡底 Stack Sheet 三片永久停用。純函式，不含任何 View 邏輯——單元測試不需要建立
/// View 就能斷言邊界。
enum AlbumThicknessTier: Equatable, Sendable {
    /// 0 張相片：不暗示「底下還有更多」（MJ-7/8 同源理由），沒有扇影。
    case empty
    /// 1–9 張。
    case thin
    /// 10–49 張。
    case medium
    /// 50+ 張。
    case thick

    init(photoCount: Int) {
        switch photoCount {
        case ..<1: self = .empty
        case 1...9: self = .thin
        case 10...49: self = .medium
        default: self = .thick
        }
    }

    /// 扇影片數。
    var fanGhostCount: Int {
        switch self {
        case .empty: 0
        case .thin: 1
        case .medium: 2
        case .thick: 3
        }
    }
}

/// 相簿 tab 首頁一張卡片組裝完成的顯示模型（`AlbumsContentAssembler` 產出）。刻意不叫
/// `AlbumContent`——那個名字已經是 `TimelineModels.AlbumContent`（時間軸相簿卡用，欄位集合
/// 不同：沒有張數／署名／分頁游標），同一個 module 內兩者不能同名，也不應該共用（服務的是
/// 不同畫面，欄位需求本來就不同）。
struct AlbumSummary: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let photoCount: Int
    /// 封面已簽名 URL（merge-review R1 M3）：`cover_media_id` 有值時用它指到的 media 列；
    /// 否則退回 `AlbumListingRow.latestMediaThumbPath`／`latestMediaStoragePath`（最新一筆
    /// album_media，見該型別文件註解）；兩者皆無（相簿沒有任何照片）才是 `nil`，呼叫端顯示
    /// 灰底占位圖。刻意只留簽名 URL、不是完整 `MediaContent`——相簿列表卡片只需要畫一張封面
    /// 縮圖，不需要 `MediaContent` 服務照片牆用的 `type`／`width`／`height`／
    /// `durationSeconds` 等欄位，fallback 分支也拿不到這些（`latest` 內嵌查詢只選了
    /// `thumb_path`／`storage_path`），硬套 `MediaContent` 只會逼出假資料填欄位。
    let cover: URL?
    /// 這本相簿標記的寶貝 id（`album_children`）——同 `TimelineFeedPointer.childIds` 的既有
    /// 慣例，組裝層只留 id，呼叫端（`AlbumsView`）依 `ChildrenStore.children` 原本順序（依
    /// birthday 排序）解析成 `[Child]`，不在這裡耦合 `ChildrenStore`（同
    /// `TimelineView.taggedChildren(for:)` 既有分工）。
    let childIds: [UUID]
    /// keyset 分頁游標用（`AlbumsStore.loadMore` 取 `entries.last`）。
    let createdAt: Date

    var thicknessTier: AlbumThicknessTier { AlbumThicknessTier(photoCount: photoCount) }
}
