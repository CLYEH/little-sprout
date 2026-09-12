import Foundation

/// 相簿 tab 首頁（LS-165，依 LS-142 稿）keyset 分頁游標——`(created_at, id)` 一對，同
/// `TimelineCursor` 的理由（見該檔文件註解）：只用 `created_at` 分頁在同一時間戳多筆相簿時
/// 會漏項／跳項（`albums_family_created_idx` 索引註解已點名這個風險），合成單一型別讓「兩者
/// 要嘛都有、要嘛都沒有」在型別層面就不可能違反。
struct AlbumsCursor: Equatable, Sendable {
    let createdAt: Date
    let id: UUID
}

/// `album_summaries`（LS-200 security-invoker view）一列，供相簿列表使用——`docs/API.md`
/// §3「albums / diaries」有完整欄位語意對照。LS-203 起改讀這支 view，不再用 PostgREST
/// 內嵌 aggregate／embed 查詢在 client 端組裝（LS-165 R1–R3 遺留的口徑差異——
/// `album_media(count)` 數的是連結列本身，不是「使用者看得見的照片數」——正是這支 view
/// 存在的理由，見 `supabase/migrations/20260905074037_album_summaries_view.sql`）：
///   - `photoCount` ← `visible_media_count`：view 已經套用呼叫者本人的 RLS
///     （`security_invoker=true`）算好，只算看得到的 media，不含已軟刪或 LS-155 刪帳號後
///     `uploaded_by` 被清成 `NULL` 的連結列。
///   - `latestMediaId`／`latestMediaThumbPath`／`latestMediaStoragePath` ← view 依
///     `created_at` 排序、可見範圍內最新一張的 media id／縮圖／原圖路徑；相簿沒有任何看得見
///     的照片時三者皆 `nil`。`latestMediaId` 本票不消費，保留給 `AlbumSummary` 轉發供
///     LS-166（相簿詳情）使用。
///   - `coverThumbPath`／`coverStoragePath` ← view 用 `cover_media_id` 反查到的縮圖／原圖
///     路徑，該媒體已軟刪／跨家庭／未指定封面時皆為 `nil`——不再需要另外解碼 `cover_media_id`
///     （UUID）本身、也不需要 `AlbumsContentAssembler` 另外呼叫 `fetchMedia` 反查，view 已經
///     把可見性判準與路徑一次算完。
struct AlbumListingRow: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let createdAt: Date
    let photoCount: Int
    let latestMediaId: UUID?
    let latestMediaThumbPath: String?
    let latestMediaStoragePath: String?
    let coverThumbPath: String?
    let coverStoragePath: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case photoCount = "visible_media_count"
        case latestMediaId = "latest_media_id"
        case latestMediaThumbPath = "latest_thumb_path"
        case latestMediaStoragePath = "latest_storage_path"
        case coverThumbPath = "cover_thumb_path"
        case coverStoragePath = "cover_storage_path"
    }

    /// 供測試／`.preview()` 假資料建構——view 回應是扁平欄位，`Decodable` 走合成的
    /// `init(from:)`（不需要像 LS-165 內嵌形狀那樣自訂解碼邏輯），這支只是讓呼叫端不必每次
    /// 都把六個彙總欄全部填滿。
    init(
        id: UUID, title: String, createdAt: Date, photoCount: Int = 0, latestMediaId: UUID? = nil,
        latestMediaThumbPath: String? = nil, latestMediaStoragePath: String? = nil,
        coverThumbPath: String? = nil, coverStoragePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.photoCount = photoCount
        self.latestMediaId = latestMediaId
        self.latestMediaThumbPath = latestMediaThumbPath
        self.latestMediaStoragePath = latestMediaStoragePath
        self.coverThumbPath = coverThumbPath
        self.coverStoragePath = coverStoragePath
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

/// `album_media` 連結表一列（LS-166，相簿詳情用）——同 `DiaryMediaLinkRow` 的角色，只是這張表
/// 沒有時間戳（見 `supabase/migrations/20260822120000_init_schema.sql` 表定義：`album_id`／
/// `media_id`／`family_id`／`sort_order`，沒有 `created_at`），排序只能靠 `sortOrder`。
/// `AlbumsStore.attachUploadedMedia`（merge-review R2 M2 起這支才是唯一的寫入端，見該方法
/// 文件註解）每次新增照片都現查一次目前連結數當基底寫入，詳情頁顯示時依 `sortOrder` 由大到小
/// 排（新加入的排最前）——見該方法文件註解。
struct AlbumMediaLinkRow: Decodable, Sendable, Equatable {
    let albumId: UUID
    let mediaId: UUID
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case albumId = "album_id"
        case mediaId = "media_id"
        case sortOrder = "sort_order"
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
    /// 封面已簽名 URL（LS-203：`AlbumListingRow` 四欄優先序 `coverThumbPath` →
    /// `coverStoragePath` → `latestMediaThumbPath` → `latestMediaStoragePath`，見
    /// `AlbumsContentAssembler.displayPath(for:)`）；四者皆無（相簿沒有任何看得見的照片）
    /// 才是 `nil`，呼叫端顯示灰底占位圖。刻意只留簽名 URL、不是完整 `MediaContent`——相簿
    /// 列表卡片只需要畫一張封面縮圖，不需要 `MediaContent` 服務照片牆用的
    /// `type`／`width`／`height`／`durationSeconds` 等欄位，硬套只會逼出假資料填欄位。
    let cover: URL?
    /// 這本相簿標記的寶貝 id（`album_children`）——同 `TimelineFeedPointer.childIds` 的既有
    /// 慣例，組裝層只留 id，呼叫端（`AlbumsView`）依 `ChildrenStore.children` 原本順序（依
    /// birthday 排序）解析成 `[Child]`，不在這裡耦合 `ChildrenStore`（同
    /// `TimelineView.taggedChildren(for:)` 既有分工）。
    let childIds: [UUID]
    /// keyset 分頁游標用（`AlbumsStore.loadMore` 取 `entries.last`）。
    let createdAt: Date
    /// `AlbumListingRow.latestMediaId` 原樣轉發（票文 Scope 2）——本票不消費，保留供
    /// LS-166（相簿詳情）使用。
    let latestMediaId: UUID?

    /// 自訂記憶體初始化子（不是合成的 memberwise init）：`latestMediaId` 給預設值
    /// `nil`——`let` 屬性若直接在宣告式給預設值，合成的 memberwise init 會把它排除在參數
    /// 之外（無法從外部覆寫，實測驗證過），要維持「大多數既有呼叫端（previews／既有測試）
    /// 不必逐一補這個參數，但 `AlbumsContentAssembler` 仍能傳入真正的值」，只能自己寫一個。
    init(
        id: UUID, title: String, photoCount: Int, cover: URL?, childIds: [UUID], createdAt: Date,
        latestMediaId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.photoCount = photoCount
        self.cover = cover
        self.childIds = childIds
        self.createdAt = createdAt
        self.latestMediaId = latestMediaId
    }

    var thicknessTier: AlbumThicknessTier { AlbumThicknessTier(photoCount: photoCount) }
}
