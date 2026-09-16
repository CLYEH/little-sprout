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

    /// merge-review R1 M4：`DateFormatter()` 建構成本高，每群各建一個——改用 `Date.FormatStyle`
    /// （Foundation 值型別，`Sendable`，天生免疫 Swift 6 嚴格並行對可變 class 的疑慮，M5 把
    /// `group(_:)` 移到 `Task.detached` 後這裡不再保證跑在 MainActor）取代，不需要快取實例。
    private static func dayKey(_ day: Date, calendar: Calendar) -> String {
        day.formatted(
            Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
                .year().month(.twoDigits).day(.twoDigits)
        )
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
    @MainActor
    static func groupHeaderLabel(for date: Date, calendar: Calendar = .current) -> String {
        monthDayFormatter.calendar = calendar
        return monthDayFormatter.string(from: date)
    }

    /// C4a②：日期不明群的標題「今天（9/15）」——「今天」＋括號內確切月日，提醒使用者這是
    /// 系統推測值、可以改（`anchorDate` 是使用者目前選定的錨點日期，不一定真的是今天）。
    @MainActor
    static func unknownDateGroupLabel(anchorDate: Date, calendar: Calendar = .current) -> String {
        slashMonthDayFormatter.calendar = calendar
        return "今天（\(slashMonthDayFormatter.string(from: anchorDate))）"
    }

    /// merge-review R1 M4：`DateFormatter()` 建構成本高——每張群卡標題都會呼叫這裡，改成
    /// 共用快取實例，只在每次呼叫時更新可能變動的 `calendar`（`Calendar` 是輕量值型別，
    /// 屬性賦值本身不貴）。`Date.FormatStyle` 試過但 zh_Hant 的 `.month().day()` 不會自動
    /// 產出「M月d日」這種固定字面格式（實測輸出 `9/10`），這裡需要的是**固定樣板**不是
    /// 「隨系統語言變化的日期呈現」，`DateFormatter.dateFormat` 才是對的工具。
    ///
    /// **merge-review R2 i3／R4 修正**：原本標 `nonisolated(unsafe)`、靠口頭不變式（「只在
    /// MainActor 呼叫」）維持安全性，reviewer 指出這不會被編譯器強制——下一個把這兩個函式
    /// 搬到背景的人不會收到警告。改成 `@MainActor static let`，讓編譯器直接擋下任何非
    /// MainActor 存取（呼叫端 `groupHeaderLabel`／`unknownDateGroupLabel` 本來就只在
    /// `ImportGroupCardView` view body 呼叫，加這個標記不改變任何現有行為）。
    @MainActor
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    @MainActor
    private static let slashMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter
    }()
}
