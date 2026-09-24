import Foundation

/// 留言（`comments`）的型別化 client 介面——LS-190（刪除留言確認）落地了 `setCommentDeleted`；
/// LS-218（留言 sheet 本體）在這裡擴充 `listComments`／`createComment`（Rule 2：只在真的有
/// 呼叫端時才加方法）。
///
/// 方法 ↔ RPC 對照（供 `docs/API.md` §4 對帳）：
///   - `setCommentDeleted` → RPC `set_comment_deleted(p_comment_id, p_deleted)`
///   - `listComments` → RPC `list_comments(p_family_id, p_target_type, p_target_id,
///     p_cursor_created_at, p_cursor_id, p_limit)`
///   - `createComment` → RPC `create_comment(p_family_id, p_target_type, p_target_id, p_body)`
///
/// `targetType` 傳純字串（`FeedKind.rawValue`：`"diary"`／`"album"`／`"media"`），不是
/// `ContentTargetType`——同 `TimelineAPIClient.toggleReaction(targetType:)` 既有慣例：這裡的
/// target 是「留言掛在哪個內容上」，跟 `ContentTargetType`（操作表的「操作對象是不是留言本身」，
/// 含 `.comment` case）是兩個不同的語意軸，混用同一個型別會讓兩種「target」的意思彼此污染。
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的 error 型別。
protocol CommentAPIClient: Sendable {
    /// 軟刪（`deleted: true`）／還原（`deleted: false`）。作者本人（仍是該家庭成員即可，
    /// 角色不拘）或該家庭 owner 皆可呼叫；見 `docs/API.md` §4 `set_comment_deleted`。
    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws

    /// keyset 分頁，游標＝`cursor`（`nil`＝第一頁）。「載入更早的留言」帶上目前最舊一則的
    /// `CommentsCursor`。回傳依 `created_at DESC, id DESC` 排序（最新的在前，同
    /// `get_family_timeline` 的既有 keyset 慣例），呼叫端自行反轉成畫面由舊到新的顯示順序
    /// （見 `CommentsStore`）。
    func listComments(
        familyID: UUID, targetType: String, targetID: UUID, cursor: CommentsCursor?, limit: Int
    ) async throws -> [CommentRecord]

    /// 回傳新留言的 `id`——`create_comment` 不回傳完整列，呼叫端（`CommentsStore`）自己拼出
    /// 樂觀插入用的 `CommentRecord`（見該檔）。
    func createComment(familyID: UUID, targetType: String, targetID: UUID, body: String) async throws -> UUID
}

/// `list_comments` 的 keyset 游標——`(createdAt, id)` 這一對要嘛都給、要嘛都不給（半游標回
/// `LS022`，同 `get_family_timeline` 既有規則）。拆成獨立型別同 `TimelineCursor` 既有慣例：
/// 一來把兩個「要嘛都給、要嘛都不給」的欄位綁成一組，二來把 `listComments` 的參數數壓在
/// SwiftLint `function_parameter_count` 上限內。
struct CommentsCursor: Equatable, Sendable {
    let createdAt: Date
    let id: UUID
}

/// `list_comments` 一列（`docs/API.md` §4）——`author_display_name`／`author_avatar_url` 由
/// RPC 內部 join `profiles`，呼叫端不需要另外查作者資料。
///
/// **LS-345 R2 訂正**：本欄位原本不解碼 `author_avatar_url`，理由寫的是「LS-177 Notes MJ-1
/// 定案留言 sheet 一律顯示沖印佔位圖」——merge-review R1（M1）回頭查 `design/littlesprout.pen`
/// 逐字稿發現這個宣稱**查無明文**：MJ-1（節點 `cPTBT`）只講頭像外框從字母圓圈換成
/// `cmp/Profile Print`（`OePXK`），該元件的 Photo 子節點 `MN0WF` 的 `fill` 本來就是真實照片，
/// 留言 sheet／按讚名單的 instance 都沒有覆寫它——稿面畫的就是「框裡有真照片」，不是「一律
/// 佔位」。這段舊註解是 LS-216 時期寫的、被本票原作者照抄未回頭對稿。現在解碼
/// `author_avatar_url`，呼叫端（`CommentsSheetView+List.swift`）用
/// `familyStore.avatarDisplayURL(rawValue:)` 換成可顯示 URL，沿用本票已加好的
/// `ProfilePrintChip(avatarURL:)`，不需要另建簽名管線。
struct CommentRecord: Identifiable, Equatable, Decodable, Sendable {
    let id: UUID
    /// 可能為 `nil`——同 `SupabaseSafetyAPIClient.AuthorIDRow` 的既有防禦：作者對應的
    /// `profiles` 列理論上不會消失（帳號刪除走 cascade），但欄位本身在資料庫是可為 NULL
    /// 的外鍵，防禦性設成 Optional。
    let authorID: UUID?
    let authorDisplayName: String
    /// Storage 路徑或 OAuth 公開網址，語意同 `Profile.avatarURL`——呼叫端一律經
    /// `FamilyStore.avatarDisplayURL(rawValue:)` 轉換，不直接拿來建 `URL`。
    ///
    /// **被封鎖者由伺服器整列過濾，client 不處理**：`list_comments`（definer，
    /// `20260913010217_comment_count.sql`）先算 `v_blocked_ids`（`private.blocked_pairs()`），
    /// 主查詢與 `total_count` 都排除作者在其中的留言——被我封鎖的人的留言整則不會回來，自然也
    /// 沒有 `author_avatar_url`；按讚名單同理由 `reactions_select` RLS 的 `blocked_pairs` 述詞
    /// （`20260906124837_reactions_block_filter.sql`）整列濾掉。不要把這層過濾搬到 client。
    ///
    /// **不另做遮蔽的只有已離開家庭／已刪帳號**：已離開家庭的作者 `author_display_name` 仍保留
    /// 當時的值（見 `list_comments` definer 文件），頭像路徑同理原樣回傳；但
    /// `FamilyStore.avatarSignedURLs` 只簽 `myProfile`＋現任 `members` 的路徑，
    /// `avatarDisplayURL(rawValue:)` 對它回 nil → 沖印佔位。已刪帳號走 `left join
    /// public.profiles`，此欄為 nil → 佔位。
    let authorAvatarURL: String?
    let body: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case authorID = "author_id"
        case authorDisplayName = "author_display_name"
        case authorAvatarURL = "author_avatar_url"
        case body
        case createdAt = "created_at"
    }
}
