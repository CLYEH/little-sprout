import Foundation

/// 對應 `public.children` 的可讀欄位子集（`list_children` RPC 回傳列，見
/// `docs/API.md` §4 `list_children`）。**不分角色、不分軟刪與否**——owner／member／viewer
/// 呼叫都會看到 active 與已軟刪的孩子，`deletedAt` 對所有人都是可見的唯讀旗標；只有「還原」
/// 這個動作（`set_child_deleted(p_deleted=false)`）限 owner，讀取本身不分角色（LS-66 R1 I3/I4）。
struct Child: Equatable, Sendable, Decodable, Identifiable {
    let id: UUID
    let name: String
    let birthday: Date
    let avatarURL: String?
    let deletedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, birthday
        case avatarURL = "avatar_url"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
    }

    var isDeleted: Bool { deletedAt != nil }

    init(id: UUID, name: String, birthday: Date, avatarURL: String?, deletedAt: Date?, createdAt: Date) {
        self.id = id
        self.name = name
        self.birthday = birthday
        self.avatarURL = avatarURL
        self.deletedAt = deletedAt
        self.createdAt = createdAt
    }

    /// `birthday` 是 Postgres `date` 欄位（`"2024-03-12"`，無時間／時區），SDK 預設的
    /// ISO8601 日期解碼策略只認得含時間的字串會直接丟錯——這裡手動用 `BirthdayFormat`
    /// 解析這一欄，`deletedAt`／`createdAt`（timestamptz）維持吃預設解碼策略。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let birthdayString = try container.decode(String.self, forKey: .birthday)
        guard let birthday = BirthdayFormat.date(fromWireString: birthdayString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .birthday,
                in: container,
                debugDescription: "無法解析 birthday：\(birthdayString)"
            )
        }
        self.birthday = birthday
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
