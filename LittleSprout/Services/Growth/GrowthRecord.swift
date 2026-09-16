import Foundation

/// 對應 `public.growth_records`（LS-255，`supabase/migrations/20260913065021_growth_records.sql`）
/// 的可讀欄位子集——`list_growth_records` RPC 回傳列（見 `docs/API.md` §4）。已軟刪的紀錄不會
/// 出現在這裡：RLS `growth_records_select` 直接濾掉 `deleted_at is not null`（同 migration
/// 註解，本票不需要像 `Child.deletedAt` 那樣自己分流在案／已移除）。
struct GrowthRecord: Equatable, Sendable, Decodable, Identifiable {
    let id: UUID
    let familyID: UUID
    let childID: UUID
    let authorID: UUID?
    let measuredOn: Date
    let heightCm: Double?
    let weightKg: Double?
    let headCm: Double?
    let note: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case familyID = "family_id"
        case childID = "child_id"
        case authorID = "author_id"
        case measuredOn = "measured_on"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case headCm = "head_cm"
        case note
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: UUID, familyID: UUID, childID: UUID, authorID: UUID?, measuredOn: Date,
        heightCm: Double?, weightKg: Double?, headCm: Double?, note: String?,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.familyID = familyID
        self.childID = childID
        self.authorID = authorID
        self.measuredOn = measuredOn
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.headCm = headCm
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `measured_on` 是 Postgres `date` 欄位（`"2026-08-20"`，無時間／時區）——同 `Child.birthday`
    /// 的既有理由，手動用 `BirthdayFormat` 解析這一欄，其餘 timestamptz 欄位吃預設解碼策略。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        familyID = try container.decode(UUID.self, forKey: .familyID)
        childID = try container.decode(UUID.self, forKey: .childID)
        authorID = try container.decodeIfPresent(UUID.self, forKey: .authorID)
        let measuredOnString = try container.decode(String.self, forKey: .measuredOn)
        guard let measuredOn = BirthdayFormat.date(fromWireString: measuredOnString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .measuredOn, in: container, debugDescription: "無法解析 measured_on：\(measuredOnString)"
            )
        }
        self.measuredOn = measuredOn
        heightCm = try container.decodeIfPresent(Double.self, forKey: .heightCm)
        weightKg = try container.decodeIfPresent(Double.self, forKey: .weightKg)
        headCm = try container.decodeIfPresent(Double.self, forKey: .headCm)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 最新值卡「8/20 測量」的日期部分（Notes `db1ET`）——`measuredOn` 固定用 UTC 抽年月日，
    /// 同 `BirthdayFormat.displayString` 的既有理由，避免裝置時區把量測日往前後位移一天。
    var measuredOnShortLabel: String {
        let components = Self.utcCalendar.dateComponents([.month, .day], from: measuredOn)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    /// 06 iPad 歷史紀錄列「8月20日」（Notes `jrsot`／`o1UI6B`）。
    var measuredOnHistoryLabel: String {
        let components = Self.utcCalendar.dateComponents([.month, .day], from: measuredOn)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }
}

/// 身高／體重／頭圍三項量測（Notes 板 `h5BNyi` `wgF5u`／`O7e9Ho`）共用的量測項列舉——
/// `GrowthSegmentedControl`／`GrowthChartCardView`／`GrowthCurve` 都依這個型別分流，避免三項
/// 各自散落成互相不同步的字串常數。
enum GrowthMetric: String, CaseIterable, Identifiable, Sendable {
    case height
    case weight
    case head

    var id: String { rawValue }

    var label: String {
        switch self {
        case .height: "身高"
        case .weight: "體重"
        case .head: "頭圍"
        }
    }

    var unit: String {
        switch self {
        case .height, .head: "cm"
        case .weight: "kg"
        }
    }

    /// SF Symbol——Notes 只畫了「icon」佔位節點，沒有指定字面圖示名稱；這裡挑語意最接近的
    /// 系統符號（身高＝尺、體重＝磅秤、頭圍＝圈選），非稿面逐字規格（PR「已完成」欄註記）。
    var systemImage: String {
        switch self {
        case .height: "ruler"
        case .weight: "scalemass"
        case .head: "circle.dashed"
        }
    }

    func value(in record: GrowthRecord) -> Double? {
        switch self {
        case .height: record.heightCm
        case .weight: record.weightKg
        case .head: record.headCm
        }
    }

    /// 抄值表 `wgF5u` 示範資料一律 1 位小數（78.5 cm／9.6 kg／45.0 cm）。
    func formattedValue(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 「較上次」列——`+5.5 cm`／`−0.9 kg`（Notes `db1ET`）。半形加號＋全形減號（`\u{2212}`，
    /// 同一般排版慣例，不用連字號 `-`）。
    func formattedDelta(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : "\u{2212}"
        return "\(sign)\(String(format: "%.1f", abs(delta))) \(unit)"
    }
}
