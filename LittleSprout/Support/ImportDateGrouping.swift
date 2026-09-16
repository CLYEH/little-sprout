import Foundation

/// 相機膠卷批次匯入的 EXIF 日期分組（LS-303 範圍 2）——純函式，同 `TimelineDayGrouping` 的
/// 既有慣例：只切分組邊界，不管畫面怎麼呈現。
enum ImportDateGrouping {
    /// 分組前的最小輸入單位——只帶分組需要的兩個欄位，呼叫端（PHPicker 選取結果，見
    /// `PhotoLibraryAccessService`）自行從 `PHAsset` 映射過來，本型別不依賴 Photos
    /// framework，方便單元測試與 SwiftUI Preview 不需要真的 `PHAsset`。
    struct PickedAsset: Equatable {
        let localIdentifier: String
        let creationDate: Date?

        init(localIdentifier: String, creationDate: Date?) {
            self.localIdentifier = localIdentifier
            self.creationDate = creationDate
        }
    }

    static let unknownDateGroupID = "unknown-date"

    /// 依 `creationDate` 所在（裝置本地時區）自然日分組、日期倒序；`creationDate == nil`
    /// 的落在單一「日期不明」群，錨點日期預設 `today`、固定排在所有已知日期群之後（LS-303
    /// 範圍 2：「無日期落『日期不明』群預設今天，可改日期」——本函式只決定分組與預設錨點，
    /// 「可改日期」是呼叫端 `ImportPlan.Group.anchorDate` 之後的使用者編輯，不在這裡）。
    static func group(
        _ assets: [PickedAsset], calendar: Calendar = .current, today: Date = Date()
    ) -> [ImportPlan.Group] {
        var order: [Date] = []
        var byDay: [Date: [String]] = [:]
        var unknownIDs: [String] = []

        for asset in assets {
            guard let creationDate = asset.creationDate else {
                unknownIDs.append(asset.localIdentifier)
                continue
            }
            let day = calendar.startOfDay(for: creationDate)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(asset.localIdentifier)
        }

        var groups = order.sorted(by: >).map { day in
            ImportPlan.Group(
                id: dayKey(day, calendar: calendar), anchorDate: day, isDateUnknown: false,
                assetLocalIdentifiers: byDay[day] ?? []
            )
        }

        if !unknownIDs.isEmpty {
            groups.append(ImportPlan.Group(
                id: unknownDateGroupID, anchorDate: calendar.startOfDay(for: today), isDateUnknown: true,
                assetLocalIdentifiers: unknownIDs
            ))
        }

        return groups
    }

    private static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}

/// 日期格式四型（`design/littlesprout.pen` Notes `mEakH`，使用者裁決 C4a：維持四型各自語意
/// 各自寫法，不統一）——本票範圍只用到①②，③（處理順序，匯入進度畫面）④（單一失敗事件
/// 定位）屬 LS-249 2/2 範圍。
enum ImportDateFormatting {
    /// C4a①：已知拍攝日期的分組標題「9月10日」——不特化今天／昨天，所有已知日期群統一這個
    /// 格式（刻意跟時間軸 `DayDividerView` 的日期章不同：那邊「今天」有特殊文案；這裡「今天」
    /// 跟其他日期一視同仁，只有「日期不明」群才會出現「今天」字樣，用來標示那是系統推測值
    /// 而非 EXIF 事實，見 `unknownDateGroupLabel`）。
    static func groupHeaderLabel(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.calendar = calendar
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// C4a②：日期不明群的標題「今天（9/15）」——「今天」＋括號內確切月日，提醒使用者這是
    /// 系統推測值、可以改（`anchorDate` 是使用者目前選定的錨點日期，不一定真的是今天）。
    static func unknownDateGroupLabel(anchorDate: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.calendar = calendar
        formatter.dateFormat = "M/d"
        return "今天（\(formatter.string(from: anchorDate))）"
    }
}
