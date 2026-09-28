import Foundation

/// `child_food_records.reaction` 的三個合法值（`child_food_records_reaction_valid` CHECK）。
/// 03 sheet 的反應三選一（LS-326 Notes `m18MTy`：liked 喜歡 smile／neutral 普通 meh／disliked 不愛吃
/// frown；可不選、已選再點一次取消）。`allCases` 的順序＝畫面上的排列順序。
enum FoodReaction: String, CaseIterable, Sendable, Identifiable {
    case liked
    case neutral
    case disliked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liked: "喜歡"
        case .neutral: "普通"
        case .disliked: "不愛吃"
        }
    }
}

/// `upsert_child_food_record` 的呼叫端輸入（6 個參數，見 `docs/API.md` §4）。`firstTriedOn` 是
/// DatePicker 選到的「裝置本地時區的某一天」，送出時由 client 以 `BirthdayFormat.wireString` 轉成
/// `yyyy-MM-dd`（同 `GrowthMeasurementInput.measuredOn`）。
struct FoodRecordUpsert: Equatable, Sendable {
    let childID: UUID
    let foodID: String
    let firstTriedOn: Date
    let mediaID: UUID?
    /// 已 trim；空字串已轉 nil（Notes `m18MTy`「trimmed.isEmpty→nil」）。
    let note: String?
    let reaction: FoodReaction?
}

/// 03d「從家庭相簿挑一張」的一張照片——`media` 表（`type = photo`、未軟刪）的可讀欄位子集。
struct FamilyPhoto: Hashable, Sendable, Decodable, Identifiable {
    let id: UUID
    let storagePath: String
    let thumbPath: String?
    let takenAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
        case takenAt = "taken_at"
        case createdAt = "created_at"
    }

    /// 縮圖優先（`docs/API.md` §6 egress 防線；`thumb_path` 為 NULL 的舊列才退回原檔，同
    /// `TimelineContentAssembler.displayPath`）。
    var displayPath: String { thumbPath ?? storagePath }

    /// 排序／分組鍵：`taken_at`，沒有才用 `created_at`（Notes `m18MTy`）。
    var sortDate: Date { takenAt ?? createdAt }
}

/// 03d 的一段（「今天拍的」／「M月d日那天拍的」／「其他照片」）。
struct FamilyPhotoSection: Equatable, Identifiable {
    let title: String
    let photos: [FamilyPhoto]

    var id: String { title }
}

/// 03d 分段規則（Notes `m18MTy`）：`sortDate` 遞減；與記錄日期（`first_tried_on`）同一天的照片另成
/// 第一段——記錄日期＝今天標「今天拍的」，否則「M月d日那天拍的」；其餘在「其他照片」，新到舊。空的段
/// 不出現。抽成純函式讓 `FamilyPhotoSectionsTests` 不建 View 就能鎖住。
enum FamilyPhotoSections {
    static func make(
        photos: [FamilyPhoto], recordDate: Date, now: Date = Date(), calendar: Calendar = .current
    ) -> [FamilyPhotoSection] {
        let sorted = photos.sorted { $0.sortDate > $1.sortDate }
        let sameDay = sorted.filter { calendar.isDate($0.sortDate, inSameDayAs: recordDate) }
        let others = sorted.filter { !calendar.isDate($0.sortDate, inSameDayAs: recordDate) }
        var sections: [FamilyPhotoSection] = []
        if !sameDay.isEmpty {
            let title = sameDayTitle(recordDate: recordDate, now: now, calendar: calendar)
            sections.append(FamilyPhotoSection(title: title, photos: sameDay))
        }
        if !others.isEmpty {
            sections.append(FamilyPhotoSection(title: "其他照片", photos: others))
        }
        return sections
    }

    static func sameDayTitle(recordDate: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(recordDate, inSameDayAs: now) { return "今天拍的" }
        let parts = calendar.dateComponents([.month, .day], from: recordDate)
        return "\(String(parts.month ?? 0))月\(String(parts.day ?? 0))日那天拍的"
    }
}
