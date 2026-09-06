import Foundation

/// `public.content_target_type` enum（`supabase/migrations/20260822120000_init_schema.sql:29`）
/// ——內容操作表（`design/littlesprout.pen` `WgbNc`）只服務日記／照片／留言三種（`album` 由
/// LS-166 相簿詳情落地後再接，見 `docs/API.md` §3 `content_reports`／`blocked_users` 段）；
/// 這裡仍把 `album` 收進 enum（跟資料庫 enum 一一對應，而不是只列票文範圍的三種）——
/// `report_content`／`remove_content_as_owner` 兩支 RPC 本來就接受全部四種，之後接相簿詳情
/// 時只需要多一個呼叫端，不需要再改這個型別。
enum ContentTargetType: String, Codable, Sendable, Equatable, CaseIterable {
    case diary, album, media, comment

    /// 檢舉收件匣（`design/littlesprout.pen` `J5sQHy`）卡片的「Type」文字與 icon——`comment`→
    /// `message.fill`／`media`→`photo`（皆稿面示範值）；`diary`／`album` 稿面沒有示範，沿用 SF
    /// Symbol 對照表（Notes）與既有慣例（`book`／`photo.stack`，同 `AlbumDetailView` 既有用法）。
    var displayLabel: String {
        switch self {
        case .diary: "日記"
        case .album: "相簿"
        case .media: "照片"
        case .comment: "留言"
        }
    }

    var icon: String {
        switch self {
        case .diary: "book"
        case .album: "photo.stack"
        case .media: "photo"
        case .comment: "message.fill"
        }
    }
}

/// 檢舉原因（`design/littlesprout.pen` `SSfdn`／`q4mb2`，LS-152 Notes「p_reason → key 對照表」
/// MN-7）——`report_content` 的 `p_reason` 是自由文字、後端沒有 enum 約束，這裡送穩定的 ASCII
/// key（不送中文），中文只在 UI 端 localize，否則 Supabase Dashboard 端的分類統計會因為使用者
/// 換字級／多語系而失準（Notes 原文）。
enum ReportReason: String, CaseIterable, Sendable, Identifiable, Equatable {
    case sexual, harassment, hate, privacy, spam, other

    var id: String { rawValue }

    /// 對照表（Notes `b28VzO`）：「色情或猥褻內容」→sexual｜「騷擾、霸凌或恐嚇」→harassment｜
    /// 「歧視或仇恨言論」→hate｜「侵害隱私或未經同意的內容」→privacy｜「詐騙或垃圾訊息」→spam｜
    /// 「其他」→other。
    var displayLabel: String {
        switch self {
        case .sexual: "色情或猥褻內容"
        case .harassment: "騷擾、霸凌或恐嚇"
        case .hate: "歧視或仇恨言論"
        case .privacy: "侵害隱私或未經同意的內容"
        case .spam: "詐騙或垃圾訊息"
        case .other: "其他"
        }
    }
}

/// `blocked_users` 一列（`docs/API.md` §3：`blocker_id = 我` 的 RLS 只讓自己讀自己封鎖的名單）
/// ——顯示名稱由呼叫端（`BlockListView`）對照 `FamilyStore.members` 解析，不在這裡內嵌
/// `profiles` join（`blocked_users` 對 `profiles` 有兩支外鍵，PostgREST embed 需要明確 FK
/// 提示，多一個查詢面不如直接沿用畫面已經有的 `familyStore.members`）。
struct BlockedUserRecord: Sendable, Decodable, Identifiable, Equatable {
    let blockedID: UUID
    let createdAt: Date

    var id: UUID { blockedID }

    enum CodingKeys: String, CodingKey {
        case blockedID = "blocked_id"
        case createdAt = "created_at"
    }
}

/// `content_reports` 一列（`docs/API.md` §3：owner 讀得到自家全部、一般成員只讀得到自己送出的
/// ——`listPendingReports` 只給 owner 用，見 `SafetyAPIClient` 文件註解）。`reason` 保留原始
/// ASCII key（可能是舊資料或非本 app 送出的自由文字，解析失敗時 `ReportReason(rawValue:)` 為
/// nil，呼叫端顯示原始字串兜底）。
struct ContentReportRecord: Sendable, Decodable, Identifiable, Equatable {
    let id: UUID
    let targetType: ContentTargetType
    let targetID: UUID
    let reporterID: UUID?
    let reason: String
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case targetType = "target_type"
        case targetID = "target_id"
        case reporterID = "reporter_id"
        case reason, status
        case createdAt = "created_at"
    }
}
