import Foundation

/// `get_family_timeline` 回傳的 `kind` 欄——`public.feed_kind` enum，PostgREST 序列化成
/// JSON 字串（見 `docs/API.md` §4 `get_family_timeline`）。
///
/// LS-329：後端 `feed_kind` 之後新增值（例如 LS-325 `food_first`）時，尚未更新的已安裝
/// app 版本仍會收到含新字串的回應——原本合成的 `String` rawValue `Decodable` 遇到無法
/// match 的字串會直接 throw，讓外層 `[TimelineFeedPointer]` 整批解碼失敗、時間軸整頁
/// 顯示錯誤（不是「少一筆」這麼輕微）。改手寫 `init(from:)`：辨識不出的字串放進
/// `.unknown(rawValue)`，讓外層陣列解碼繼續成功；呼叫端
/// （`TimelineContentAssembler.assemble`）把 `.unknown` 這筆濾掉並記一行 log，不顯示、
/// 也不讓它走進任何需要 ref 詳情的導頁（見該檔）。無法再用 `String` 做 raw value 型別
/// （帶關聯值的 case 不能與 raw value 並存），`rawValue` 改手寫計算屬性，語意對既有呼叫端
/// （`CommentsSheetView`／`InteractionRow`／`TimelineStore+Reactions`／`TimelineEntry.id`）
/// 透明——這些呼叫端只會拿到已知 kind 的 entry（`.unknown` 在更早的階段就被濾掉），
/// `.unknown` 分支在這裡只是滿足編譯器窮舉要求，不是預期路徑。
enum FeedKind: Decodable, Sendable, Hashable {
    case diary, album, media
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "diary": self = .diary
        case "album": self = .album
        case "media": self = .media
        default: self = .unknown(raw)
        }
    }

    var rawValue: String {
        switch self {
        case .diary: return "diary"
        case .album: return "album"
        case .media: return "media"
        case .unknown(let raw): return raw
        }
    }
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
    /// LS-243：`comment_count`——未刪除、排除呼叫者已封鎖的作者的留言數（見
    /// `docs/API.md` 對這支 RPC 的說明）。
    let commentCount: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case refId = "ref_id"
        case occurredAt = "occurred_at"
        case childIds = "child_ids"
        case commentCount = "comment_count"
    }

    /// 手寫 memberwise 初始化（取代合成版）——只給 `commentCount` 一個預設值，讓既有測試
    /// 呼叫端（`TimelineFeedPointer(kind:refId:occurredAt:childIds:)`）不必逐一補這個新
    /// 參數，同 `childIds` 之於更早既有呼叫端的既有慣例。寫了這支之後 Swift 就不會再合成
    /// 免費的 memberwise init，兩者只能二選一——這裡選手寫版本，因為下面 `init(from:)`
    /// 也是手寫的（`decodeIfPresent` 需要自訂解碼邏輯，合成的 `Decodable` 版本做不到）。
    init(kind: FeedKind, refId: UUID, occurredAt: Date, childIds: [UUID], commentCount: Int = 0) {
        self.kind = kind
        self.refId = refId
        self.occurredAt = occurredAt
        self.childIds = childIds
        self.commentCount = commentCount
    }

    /// merge-review R1 i1：`comment_count` 用 `decodeIfPresent(...) ?? 0`，不是合成
    /// `Decodable` 那種「key 不存在就整個解碼失敗」——這支 app build 可能先於本票 migration
    /// 推上某個環境（例如 QA 在 `test` branch 用真後端驗收，若當下 `development`／`test`
    /// 資料庫還沒套用這支 migration），舊 DB 的 `get_family_timeline` 回應不會有
    /// `comment_count` 這個 key，若當成必要欄位，整批 `fetchTimelinePointers` 會直接
    /// throw、時間軸整頁變 `.failure`（不是「少顯示一個數字」這麼輕微）。`decodeIfPresent`
    /// 讓舊 DB＋新 app 這個部署順序組合退化成「留言計數暫時看不到（顯示 0）」，不是整頁
    /// 打不開；新 DB＋新 app（正常情況）解到真正的值。反向（舊 app＋新 DB）本來就安全
    /// （多出來、未宣告的 key 被忽略，不受這裡影響）。見
    /// `SupabaseTimelineAPIClientTests.test_fetchTimelinePointers_missingCommentCountKey_decodesToZero`。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(FeedKind.self, forKey: .kind)
        refId = try container.decode(UUID.self, forKey: .refId)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        childIds = try container.decode([UUID].self, forKey: .childIds)
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
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
    /// 縮圖三欄（LS-128，nullable，皆同為 `NULL` 或同為非 `NULL`，`media_thumb_dimensions_
    /// consistency` CHECK 保證，見 migration `20260902101842_media_thumb_path.sql`）——
    /// `thumbPath` 為 `NULL` 表示既有列或縮圖產生失敗，讀取端退回 `storagePath`（見
    /// `TimelineContentAssembler.displayPath`，docs/API.md §6「簽名 URL 與 egress 防線」）。
    let thumbPath: String?
    let thumbWidth: Int?
    let thumbHeight: Int?
    /// 影片時長（整數秒，`media.duration_seconds`，LS-134）——nullable：`type == .photo`
    /// 恆為 `NULL`；`type == .video` 時 LS-135 起由上傳端以 `AVAsset` 量測寫入，既有舊列
    /// （LS-135 之前上傳）仍是 `NULL`，讀取端退回 `TimelineStore.loadVideoDuration` 的
    /// client-side 查表（見 `MediaContent.needsVideoDurationLookup`）。`.select()` 不指定
    /// 欄位＝select *，這一欄不需要額外的 grant 或 RPC 改動就會隨既有查詢一起回來（見
    /// `20260902195055_media_duration_seconds.sql`：SELECT 是整表 grant，只有 UPDATE 才逐欄
    /// 列舉）。
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case type, width, height
        case thumbPath = "thumb_path"
        case thumbWidth = "thumb_width"
        case thumbHeight = "thumb_height"
        case durationSeconds = "duration_seconds"
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
    /// 縮圖實際輸出的像素寬高（`media.thumb_width`／`thumb_height`，LS-128）——nullable，
    /// 見 `aspectRatio`：瀑布流版面計算比例優先用這組，NULL 才退回 `width`／`height`。
    let thumbWidth: Int?
    let thumbHeight: Int?
    /// 原始檔案的 Storage 路徑（`media.storage_path`）——僅供放大檢視／播放影片時現簽
    /// 全尺寸 URL（`TimelineStore.signFullSizeURL`）用，列表／縮圖情境不使用這個路徑
    /// 簽名（見 `signedURL`、docs/API.md §6「簽名 URL 與 egress 防線」）。
    let storagePath: String
    /// R2-M1（merge-review `b7ecfbf4` M1）：`true`＝`signedURL` 現在指向的是縮圖 JPEG，不是
    /// 可播放／可解出時長的原始檔案——`type == .video` 且這個欄位為 `true` 時，呼叫端
    /// （`PhotoCardView`／`MasonryPhotoWallView`）不該再拿 `signedURL` 去打
    /// `TimelineStore.loadVideoDuration`，那必定失敗且沒有必要浪費一次網路請求。跟
    /// `thumbWidth != nil` 邏輯上等價（DB `media_thumb_dimensions_consistency` CHECK 保證
    /// 縮圖三欄同進退），但獨立成顯式欄位、不倚賴那個不變式——語意更直接，這裡的判準只看
    /// 「這個 `signedURL` 是不是縮圖」，跟 CHECK 保證的是不是三欄一致是兩個問題，未來就算
    /// CHECK 調整也不會悄悄牽動這裡。
    let isThumbnail: Bool
    /// 列表／縮圖情境用的簽名 URL：`thumb_path` 有值時簽縮圖，NULL 時退回 `storagePath`
    /// （見 `TimelineContentAssembler.displayPath`）。簽名失敗（見
    /// `TimelineAPIClient.signedURLs`）時為 nil——呼叫端顯示占位圖，不讓整頁因為單一
    /// 檔案簽名失敗而整批失敗。
    let signedURL: URL?
    /// 影片時長（秒，`media.duration_seconds`，LS-134／135）——`MediaRow.durationSeconds`
    /// 原樣帶過來。`nil` 表示照片，或影片為既有舊列（LS-135 之前上傳、量測失敗）；有值時
    /// 徽章（`VideoDurationBadge`）直接顯示這個查表值，不需要客戶端對簽名 URL 做媒體解碼
    /// （docs/API.md §6「影片時長徽章讀取策略」）。
    let durationSeconds: Int?

    /// 寬高比（寬／高），用於瀑布流等比縮放；優先用縮圖實際尺寸（`thumbWidth`／
    /// `thumbHeight`，LS-130：格內顯示的就是縮圖，比例該跟著縮圖走，不必等原圖尺寸），
    /// 兩者任一為 `nil` 時退回原圖 `width`／`height`。皆為正整數時才計算，否則退回 1
    /// （`media` 表 `CHECK (width > 0)`／`CHECK (height > 0)`／縮圖同款 CHECK，理論上
    /// 不會是 0，這裡是防禦）。
    var aspectRatio: CGFloat {
        let effectiveWidth = thumbWidth ?? width
        let effectiveHeight = thumbHeight ?? height
        guard effectiveWidth > 0, effectiveHeight > 0 else { return 1 }
        return CGFloat(effectiveWidth) / CGFloat(effectiveHeight)
    }

    /// R2-M1（merge-review `b7ecfbf4`）／LS-135：`PhotoCardView`／`MasonryPhotoWallView`／
    /// `DiaryCardView` 的 `.task(id:)` 該不該呼叫 `TimelineStore.loadVideoDuration` 的判斷——
    /// 只有影片、`durationSeconds` 還沒有查表值（`nil`，LS-135 之前上傳的舊列或量測失敗）、
    /// 且 `signedURL` 不是縮圖時才值得讀時長；`durationSeconds` 有值時已經是權威查表結果，
    /// 縮圖 JPEG 也解不出時長，兩種情況讀了都必定是浪費或失敗。抽成獨立、可單元測試的屬性，
    /// 而不是散落在三個呼叫端各自的 `.task` guard 裡：SwiftUI View 的 `.task` 本身在這個
    /// repo 沒有可執行的單元測試路徑（見 `PhotoCardView`／`MasonryPhotoWallView` 皆無對應
    /// 測試檔），但這條規則的邏輯本身不需要 View 就能釘住。
    var needsVideoDurationLookup: Bool {
        type == .video && !isThumbnail && durationSeconds == nil
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
    /// LS-243：`get_family_timeline` 回傳的 `comment_count`（未刪除、排除呼叫者已封鎖的
    /// 作者的留言數）——`TimelineContentAssembler.buildEntries` 原樣帶過來，
    /// `TimelineStore.refresh`／`loadMore` 用它初始化 `commentCounts`（開留言 sheet 之前
    /// 互動列就顯示伺服器算好的計數，不再恆為 0，見 `commentCounts` 文件註解）。預設 `0`：
    /// 同 `TimelineFeedPointer.commentCount` 的既有理由，測試直接建構 `TimelineEntry(...)`
    /// 不必逐一補這個新參數。
    var commentCount: Int = 0
    /// 該筆內容組裝失敗（例如批次查詢那一支剛好失敗）時為 nil——呼叫端跳過渲染這一列，
    /// 不讓整頁因單一項目失敗而整批消失（見 `TimelineContentAssembler`）。
    let content: Content?

    /// 同時涵蓋三種 kind 的複合鍵——`ref_id` 理論上跨表不會相撞，但 `kind` 一起入 id
    /// 讓「同一頁三種 kind 各查各的表」這件事在型別層面就不可能因為 UUID 巧合碰撞。
    var id: String { Self.id(kind: kind, refId: refId) }

    /// LS-216：`TimelineStore.reactionStates`／`commentCounts` 的字典鍵——與 `id` 用同一個
    /// 公式，抽成 `static` 讓 `InteractionRow`（拿不到完整 `TimelineEntry`，只有
    /// `kind`／`refId`）也能算出同一把鍵，不必各自重寫格式字串。
    static func id(kind: FeedKind, refId: UUID) -> String { "\(kind.rawValue)_\(refId.uuidString)" }
}

/// LS-216：單一 target（diary／album／media）的愛心反應狀態——`TimelineStore.reactionStates`
/// 的 value 型別。`count`／`reactedByMe` 分開存放（不是只存一個 bool）：`toggle_reaction` 只
/// 回傳切換後的 `reactedByMe`，不回傳計數，樂觀更新需要獨立維護 `count`（見
/// `TimelineStore.toggleReaction` 文件註解）。
struct ReactionState: Equatable, Sendable {
    var count: Int
    var reactedByMe: Bool

    static let zero = ReactionState(count: 0, reactedByMe: false)
}

/// `get_reaction_counts` 一列（docs/API.md §4）。
struct ReactionCountRow: Decodable, Sendable, Equatable {
    let targetID: UUID
    let reactionCount: Int
    let reactedByMe: Bool

    enum CodingKeys: String, CodingKey {
        case targetID = "target_id"
        case reactionCount = "reaction_count"
        case reactedByMe = "reacted_by_me"
    }
}

/// 按讚名單 sheet（`GZ3pb`）一列——直接 SELECT `reactions` join `profiles`（LS-216 票文
/// scope 3：「無需新 RPC」），取顯示名稱與頭像路徑。
///
/// **LS-345 R2**：原本不取 `avatar_url`——舊註解宣稱依 LS-177 Notes MJ-1「一律沖印佔位」，
/// merge-review R1（M1）查證這個決策不成立（見 `CommentAPIClient.swift` 文件註解同一段訂正）。
/// 現在 `SupabaseTimelineAPIClient.reactors(…)` 的 `.select(...)` 多取 `avatar_url`，這裡多解
/// 一個欄位，呼叫端（`LikersListSheet.likerRow`）用 `familyStore.avatarDisplayURL(rawValue:)`
/// 換成可顯示 URL——沿用 `FamilyStore.avatarSignedURLs` 既有的簽名快取（跟留言作者頭像同一份
/// 快取，只要 `familyStore.members` 已查過，按讚者的頭像路徑多半已經簽好；`LikersListSheet`
/// 補一個同款 guard task，理由見該檔），不新建平行的簽名管線。
struct ReactorRow: Decodable, Sendable, Equatable, Identifiable {
    let userID: UUID
    let displayName: String
    let avatarURL: String?

    var id: UUID { userID }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case profile = "profiles"
    }

    enum ProfileCodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }

    /// LS-216 R2（merge-review R1 M3）：`profiles` 巢狀 embed 改成可選解碼——按讚者退出家庭
    /// 後，`profiles_select`（`security invoker`，`peer_profile_ids()` 只認「目前」同家庭的
    /// 人）會把那一列濾掉，PostgREST 的 embed 對「有外鍵、但關聯列被 RLS 擋下」回傳
    /// `"profiles": null`（不是整列消失，`reactions` 本身那一列還在）。原本 `nestedContainer`
    /// 對 null 值會拋錯，讓整份 `[ReactorRow]` 解碼失敗、按讚名單整個開不出來——只因為其中
    /// 一位按讚者離開了家庭，不成比例。改用 `try?` 吞掉「拿不到巢狀容器」或「拿不到
    /// display_name」兩種情況，顯示名稱退回「家人」（純資訊性列表，仍能看到「有 N 人按讚」，
    /// 只是其中一位顯示為通用稱呼，不影響功能）。**LS-345 R2**：`avatarURL` 沿用同一個
    /// `try?` 巢狀容器——拿不到 profile 時頭像同樣是 nil（退回沖印佔位），與顯示名稱的降級
    /// 規則一致，不另外判斷「被封鎖／已離開」。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(UUID.self, forKey: .userID)
        if let profile = try? container.nestedContainer(keyedBy: ProfileCodingKeys.self, forKey: .profile) {
            displayName = (try? profile.decode(String.self, forKey: .displayName)) ?? "家人"
            avatarURL = try? profile.decode(String.self, forKey: .avatarURL)
        } else {
            displayName = "家人"
            avatarURL = nil
        }
    }

    init(userID: UUID, displayName: String, avatarURL: String? = nil) {
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
