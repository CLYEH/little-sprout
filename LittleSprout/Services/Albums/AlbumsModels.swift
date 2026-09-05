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
struct AlbumListingRow: Decodable, Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let coverMediaId: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case coverMediaId = "cover_media_id"
        case createdAt = "created_at"
    }
}

/// `album_media` 連結表一列——只用來算「這本相簿有幾張相片」（相簿列表卡片的扇影厚度分級
/// 依據），不需要 `sort_order`（那是相簿詳情瀑布流排序才需要的欄位，LS-166 範圍）。
struct AlbumMediaLinkRow: Decodable, Sendable, Equatable {
    let albumId: UUID
    let mediaId: UUID

    enum CodingKeys: String, CodingKey {
        case albumId = "album_id"
        case mediaId = "media_id"
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
    /// 封面：`cover_media_id` 指到的 media 列組裝出的已簽名縮圖；`nil` 時（未指定封面，或
    /// 該 media 列讀不到）呼叫端顯示占位圖（同 `TimelineContentAssembler.fetchAlbumContents`
    /// 既有行為——這裡刻意不额外實作「取 album_media 最新一筆」的 fallback，見
    /// `AlbumsContentAssembler` 文件註解）。
    let cover: MediaContent?
    /// 這本相簿標記的寶貝 id（`album_children`）——同 `TimelineFeedPointer.childIds` 的既有
    /// 慣例，組裝層只留 id，呼叫端（`AlbumsView`）依 `ChildrenStore.children` 原本順序（依
    /// birthday 排序）解析成 `[Child]`，不在這裡耦合 `ChildrenStore`（同
    /// `TimelineView.taggedChildren(for:)` 既有分工）。
    let childIds: [UUID]
    /// keyset 分頁游標用（`AlbumsStore.loadMore` 取 `entries.last`）。
    let createdAt: Date

    var thicknessTier: AlbumThicknessTier { AlbumThicknessTier(photoCount: photoCount) }
}
