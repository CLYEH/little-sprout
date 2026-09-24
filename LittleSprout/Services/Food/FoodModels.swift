import Foundation

/// `food_catalog.category` 的 8 個值（`food_catalog_category_valid` CHECK，見
/// `supabase/migrations/20260918205141_food_encyclopedia.sql`）。`allCases` 的順序＝圖鑑分頁順序
/// （LS-326 Notes `v5KLRQ`：穀物根莖／蔬菜／水果／肉魚蛋豆／乳製品／油脂堅果／台灣家常／點心
/// 飲品，2×4；AX3 4×2）。
///
/// 解碼刻意嚴格（未知值＝整批解碼失敗、落到錯誤態）：DB 端 CHECK 把值域釘死在這 8 個，新增類別
/// 必須先過 migration（BREAKING 審查），不會在 app 不知情下悄悄出現——與其默默把新類別的食物藏起來
/// 讓計數句對不上，不如大聲失敗（fail loud）。
enum FoodCategory: String, CaseIterable, Sendable, Decodable, Identifiable {
    case grainRoot = "grain_root"
    case vegetable
    case fruit
    case protein
    case dairy
    case fatNut = "fat_nut"
    case twHome = "tw_home"
    case snackDrink = "snack_drink"

    var id: String { rawValue }

    /// 分頁與類別標題文字（Notes `v5KLRQ` 對應表逐字）。
    var displayName: String {
        switch self {
        case .grainRoot: "穀物根莖"
        case .vegetable: "蔬菜"
        case .fruit: "水果"
        case .protein: "肉魚蛋豆"
        case .dairy: "乳製品"
        case .fatNut: "油脂堅果"
        case .twHome: "台灣家常"
        case .snackDrink: "點心飲品"
        }
    }
}

/// 對應 `public.food_catalog` 一列（LS-325，`docs/API.md` §3 `food_catalog`）。全域唯讀目錄，
/// `id` 同時是貼紙資產名（`design/food-stickers/stickers/<id>.png`，F3a）。
struct FoodCatalogItem: Hashable, Sendable, Decodable, Identifiable {
    let id: String
    let nameZh: String
    let category: FoodCategory
    let sortOrder: Int
    /// `egg`／`milk`／`peanut`／`tree_nut`／`shellfish`／`fish`／`wheat`／`soy`／`sesame`／`mango`
    /// 的子集，順序照 DB 陣列（「含〇〇等」取第一種，見 `FoodBookCopy.allergenTag`）。
    let allergens: [String]
    /// 「一歲前不建議」的品項為 `12`，其餘 `nil`（純資訊，F2a）。
    let minAgeMonths: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case nameZh = "name_zh"
        case category
        case sortOrder = "sort_order"
        case allergens
        case minAgeMonths = "min_age_months"
    }
}

/// 對應 `public.child_food_records` 的可讀欄位子集（`list_child_food_records` RPC 回傳列，
/// `docs/API.md` §4）。已軟刪的紀錄不會出現（RLS `child_food_records_select` 直接濾掉），同
/// `GrowthRecord`。`reaction` 維持原字串——本票只讀「有沒有這一筆」與日期，反應三選一的呈現
/// 在記錄詳情票（LS-381）。
struct ChildFoodRecord: Hashable, Sendable, Decodable, Identifiable {
    let id: UUID
    let familyID: UUID
    let childID: UUID
    let foodID: String
    let authorID: UUID?
    /// `first_tried_on` 是 Postgres `date`——同 `GrowthRecord.measuredOn`，解成 UTC 午夜，顯示時
    /// 一律用 UTC 抽年月日（`FoodBookCopy.cellDate`）。
    let firstTriedOn: Date
    let mediaID: UUID?
    let note: String?
    let reaction: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case familyID = "family_id"
        case childID = "child_id"
        case foodID = "food_id"
        case authorID = "author_id"
        case firstTriedOn = "first_tried_on"
        case mediaID = "media_id"
        case note
        case reaction
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: UUID, familyID: UUID, childID: UUID, foodID: String, authorID: UUID?, firstTriedOn: Date,
        mediaID: UUID?, note: String?, reaction: String?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.familyID = familyID
        self.childID = childID
        self.foodID = foodID
        self.authorID = authorID
        self.firstTriedOn = firstTriedOn
        self.mediaID = mediaID
        self.note = note
        self.reaction = reaction
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        familyID = try container.decode(UUID.self, forKey: .familyID)
        childID = try container.decode(UUID.self, forKey: .childID)
        foodID = try container.decode(String.self, forKey: .foodID)
        authorID = try container.decodeIfPresent(UUID.self, forKey: .authorID)
        let firstTriedOnString = try container.decode(String.self, forKey: .firstTriedOn)
        guard let firstTriedOn = BirthdayFormat.date(fromWireString: firstTriedOnString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .firstTriedOn, in: container, debugDescription: "無法解析 first_tried_on：\(firstTriedOnString)"
            )
        }
        self.firstTriedOn = firstTriedOn
        mediaID = try container.decodeIfPresent(UUID.self, forKey: .mediaID)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        reaction = try container.decodeIfPresent(String.self, forKey: .reaction)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
