import Foundation

/// 記錄詳情 04 家族（LS-381，`design/littlesprout.pen` `B8krzV`／`ygv7k`〔深色〕／`z1Pg2`〔AX3〕／`orGax`〔iPad〕／
/// `gIo3O`〔04b 無照片〕／`vr5zj`〔04b AX3〕／`GRB0y`〔04b 深色〕／`Z8zWzZ`〔04c 非作者 owner〕）上看得到的
/// 動作鈕。
enum FoodRecordDetailAction: Equatable, CaseIterable {
    /// 「編輯這筆記錄」（`cmp/Button Secondary` pencil）——開 03b 編輯 sheet（LS-380）。
    case edit
    /// 「刪除這筆記錄」（`cmp/Button Text` trash-2，`$danger`）——開 03c 刪除確認（LS-380）。
    case delete
}

/// 詳情頁要交給呼叫端處理的路由——sheet 本身屬 LS-380，本票只把「要開哪一張」交出去。
enum FoodRecordDetailRoute: Equatable {
    /// 作者按「編輯這筆記錄」→ 03b。
    case edit(ChildFoodRecord)
    /// 非作者 owner 按「刪除這筆記錄」→ 03c（確認 sheet 墊在 04c 之上，Notes `hqrit` 呼叫路徑②）。
    case delete(ChildFoodRecord)
    /// 作者點 04b 空白沖印品 → 03 的兩種照片來源（挑家庭相簿／新拍，Notes `xFvkL`）。
    case addPhoto(ChildFoodRecord)
}

/// 04 家族的文案與權限判斷——抽成純函式，`FoodRecordDetailCopyTests` 不建 View 就能鎖住逐字文案、
/// 日期章格式與權限三態。
enum FoodRecordDetailCopy {
    // MARK: - 權限（Notes `J8qvq5`、04c `Z8zWzZ` Owner Note `z8d09`）

    /// 詳情頁顯示哪些動作鈕（Notes `J8qvq5`：「編輯只限原作者；非作者的 owner：04c（編輯鈕換成 `$danger`
    /// 文字鈕『刪除這筆記錄』→ 03c）；其他成員看詳情不顯示任何動作」）：
    /// - 作者本人且仍是 owner／member（`canRecord`）→ 只有「編輯」。作者的刪除入口在 03b 編輯 sheet 內
    ///   （Notes `hqrit` 刪除確認呼叫路徑①），詳情頁本身不放刪除鈕（04 `B8krzV` 只畫編輯鈕）。
    ///   `canRecord` 也要成立：`child_food_records_update` RLS 要求作者「仍是該家庭 owner/member」
    ///   （`docs/API.md` §3），作者被降為 viewer 後按編輯必得 42501，不給這顆鈕。
    /// - 不是作者、但是該家庭 owner → 只有「刪除」（`delete_child_food_record` 放行 owner，`docs/API.md` §4）。
    /// - 其他（非作者 member、viewer、`currentUserID` 未知）→ 沒有任何動作。
    /// `authorID == nil`（作者已刪帳，`on delete set null`）視為「不是我」，同 `ContentActions.swift` 慣例。
    static func actions(
        authorID: UUID?, currentUserID: UUID?, isFamilyOwner: Bool, canRecord: Bool
    ) -> [FoodRecordDetailAction] {
        if let authorID, let currentUserID, authorID == currentUserID, canRecord {
            return [.edit]
        }
        return isFamilyOwner ? [.delete] : []
    }

    static let editTitle = "編輯這筆記錄"
    static let deleteTitle = "刪除這筆記錄"

    // MARK: - 日期章（Notes `vMFj3` MN-1）

    /// 日期章文字「yyyy年M月d日 第一次吃到」（詳情一律帶年、不補零；稿 `n8uwKm` 逐字）。`twoLines`＝AX 字級：
    /// 日期與「第一次吃到」之間明確換行（稿 `BwfLB`「2026年6月8日\n第一次吃到」），不讓系統在字中間斷。
    /// `firstTriedOn` 是 UTC 午夜（`ChildFoodRecord` 解碼），用 UTC＋固定西曆抽年月日——同
    /// `FoodBookCopy.cellDate` 的理由（裝置曆法設成民國曆也不會印出 115 年）。
    static func stampText(firstTriedOn: Date, twoLines: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: firstTriedOn)
        let date = "\(String(parts.year ?? 0))年\(String(parts.month ?? 0))月\(String(parts.day ?? 0))日"
        return "\(date)\(twoLines ? "\n" : " ")第一次吃到"
    }

    // MARK: - 沖印品壓印行與記錄者

    /// 壓印行署名「暱稱 · 年齡」——年齡＝`first_tried_on` 當天（Notes `vMFj3`「年齡＝first_tried_on 當天的
    /// BirthdayFormat.ageDescription，字元硬化同 LS-367 L0xP2」），字元規則直接走
    /// `AlbumSignatureFormatter.segment`（「·」後 U+00A0、年齡內 U+00A0／U+2060），與時間軸照片卡同源。
    /// `timeZone` 固定 UTC：`firstTriedOn` 與 `birthday` 都是 UTC 午夜，用裝置時區抽「那一天」在 UTC−N
    /// 時區會退一天，算出少一個月的年齡。
    static func imprintCaption(child: Child, firstTriedOn: Date) -> String {
        AlbumSignatureFormatter.segment(for: child, asOf: firstTriedOn, timeZone: TimeZone(identifier: "UTC")!)
    }

    /// 「媽媽記錄」（稿 `ljup8`）——`display_name` 取自 `profiles`（同家庭成員互看，`docs/API.md` §2）。
    static func recordedBy(displayName: String) -> String { "\(displayName)記錄" }

    /// 04d 非作者看沒有照片的記錄：窗內唯讀的一句話（稿 `ZmJ6Z`，三種字級同一字串、不帶換行）。
    static let noPhoto = "這筆沒有照片"

    /// 04e 照片載入失敗（稿 `a9LzC`／`U8Yoq`，失敗文案鍵 `food.photo_load_failed`）。
    static let photoLoadFailed = "照片沒有載入"
    static let retryPhoto = "再試一次"

    /// 04b 空白沖印品的邀請句（稿 `R0Ys6N`「加一張第一次吃南瓜的照片」）。
    static func addPhotoLabel(foodName: String) -> String { "加一張第一次吃\(foodName)的照片" }

    // MARK: - 反應（Notes `m18MTy`）

    /// `reaction` 原字串 → 反應（顯示文字＝`FoodReaction.label`，與 03 sheet 單一來源）；`nil` 或 CHECK 之外的值
    /// （理論上不會出現）＝整個反應 chip 隱藏，不讓英文代碼露出在畫面上。
    static func reaction(_ raw: String?) -> FoodReaction? {
        raw.flatMap(FoodReaction.init(rawValue:))
    }

    // MARK: - 過敏原 info 句（Notes `v5KLRQ`、R3 MJ-3）

    /// 詳情頁長版過敏原名：`wheat` 寫完整「麩質（小麥、燕麥等穀物）」，其餘沿用格子的對應表
    /// （`FoodBookCopy.allergenNames`，單一來源）。
    static func allergenLongName(_ code: String) -> String {
        code == "wheat" ? "麩質（小麥、燕麥等穀物）" : FoodBookCopy.allergenNames[code] ?? "過敏原"
    }

    /// 過敏原 info 句（稿 `dl1RU` 逐字）：「含〇〇，是常見過敏原。只是提醒，不是醫療建議；有疑問請問醫師。」
    /// 多種時逐項列出、以「、」串接（Notes `v5KLRQ`「多種時逐項列出」；布丁＝「含牛奶、蛋，…」）。
    /// 沒有過敏原＝nil，整列隱藏（Notes `v5KLRQ`「沒有過敏原的食物整列隱藏」，04b 南瓜）。
    static func allergenSentence(_ allergens: [String]) -> String? {
        guard !allergens.isEmpty else { return nil }
        let names = allergens.map(allergenLongName).joined(separator: "、")
        return "含\(names)，是常見過敏原。只是提醒，不是醫療建議；有疑問請問醫師。"
    }
}
