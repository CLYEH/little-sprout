import Foundation

/// 02 新增／編輯量測 sheet（LS-313，`design/littlesprout.pen` Notes `iG56w`／`GpxTB`／
/// `hQpxd`）的表單驗證純函式——不依賴 View／Store，方便 `GrowthMeasurementValidationTests`
/// 直接窮舉邊界情境（同 `GrowthCurve`／`ContentActions.swift` 的既有慣例）。
///
/// 兩層規則刻意分開（Notes 明寫「兩者是不同插槽，勿混淆」）：
/// - `hasAtLeastOneValue`：**硬性**——三項全空擋下儲存，訊息在 Footer 的 Status Slot。
/// - `rangeWarning`：**軟性提醒**——即使超出範圍，`disable 儲存` 一律不成立（品牌第 8 條），
///   訊息在 Measurement Group 下方的 Range Warning Slot，只是提醒使用者「這樣真的沒填錯？」。
enum GrowthMeasurementValidation {
    /// 身高／體重／頭圍三項至少要填一項（`growth_records_measurement_required` CHECK
    /// 約束，`docs/API.md` §3）——這裡在送出前就先擋，不必等 RPC 回 `23514` 才知道。
    static func hasAtLeastOneValue(heightCm: Double?, weightKg: Double?, headCm: Double?) -> Bool {
        heightCm != nil || weightKg != nil || headCm != nil
    }

    /// R1 merge-review m1：decimalPad 在小數點用逗號的地區（裝置 `Locale` 十進位分隔字元為
    /// `,`）會打出像 `"9,6"` 這樣的文字，`Double("9,6")` 解析為 `nil`、被靜默當成沒填——這裡
    /// 先把逗號正規化成半形點再解析（codebase 沒有現成的 Locale-aware 數字解析慣例，用最小
    /// 改法處理這一種分隔字元差異，不用整套 `NumberFormatter`）。解析成功後四捨五入到一位
    /// 小數（票文「小數一位」——避免打兩位小數存進去，`%.1f` 只是顯示格式化，實際存的值沒被
    /// 改，下次編輯回填、原封不動存回去，跟畫面顯示的一位小數不一致）；並擋 `<= 0`（`growth_
    /// records_height_positive` 等 DB CHECK 約束的前端版本，給清楚的「沒填」而不是等 RPC 回
    /// `23514`）與超出 `numeric` 欄位容量的超大值（`height_cm`／`head_cm` 是 `numeric(5,1)`、
    /// `weight_kg` 是 `numeric(5,2)`——三項共用同一個保守上限 `maxValidValue`，遠低於兩者的
    /// 實際容量，也遠超過任何真實人體量測值，前端擋下比等 RPC 回 `22003` 友善）。回傳 `nil`
    /// 代表這個字串目前不是有效輸入，同「這欄沒填」一視同仁處理（不擋儲存，見型別文件註解，
    /// 只是這個值不會被送出）。
    static func parsedMeasurement(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0, value <= maxValidValue else { return nil }
        return (value * 10).rounded() / 10
    }

    private static let maxValidValue = 999.9

    /// 「超出合理範圍」的軟性提醒——刻意用固定絕對門檻，不是依年齡換算的百分位（票文「不做：
    /// 參考帶」已排除百分位計算）。R1 merge-review M4（orchestrator 裁決 `d55ff9ac` 第 5 條）：
    /// 這是單純的**手誤攔截**，不是同齡比較——上限擋「多打一個位數」（例如想輸入 18.0 kg 體重
    /// 卻打成 180），下限擋「漏打小數點」（例如想輸入 45.0 cm 頭圍卻打成 4.5）。範圍刻意夠寬，
    /// 涵蓋新生兒到成人的合理量測值，不是「該年齡的正常範圍」，三項各自獨立檢查（同
    /// `GrowthCurve` 三條曲線互不影響的既有精神），只回傳**第一個**超出範圍的項目（Range
    /// Warning Slot 只有一個插槽，不會同時列三條警語）——依身高／體重／頭圍的檢查順序，同
    /// 表單欄位的視覺順序一致。
    static func rangeWarning(heightCm: Double?, weightKg: Double?, headCm: Double?) -> String? {
        if let heightCm, !heightRange.contains(heightCm) {
            return warningMessage(metric: .height, value: heightCm)
        }
        if let weightKg, !weightRange.contains(weightKg) {
            return warningMessage(metric: .weight, value: weightKg)
        }
        if let headCm, !headRange.contains(headCm) {
            return warningMessage(metric: .head, value: headCm)
        }
        return nil
    }

    private static let heightRange = 30.0...200.0
    private static let weightRange = 1.0...150.0
    private static let headRange = 25.0...70.0

    /// orchestrator 裁決 `d55ff9ac` 第 5 條例句：「身高 180.0 cm 看起來不太尋常。如果沒有打
    /// 錯，直接儲存就可以。」——文案刻意不提「同齡」（門檻是年齡無關的絕對值，見上），也不分
    /// 「太高／太重／太大」或「太矮／太輕／太小」，統一用「看起來不太尋常」。
    private static func warningMessage(metric: GrowthMetric, value: Double) -> String {
        "\(metric.label) \(metric.formattedValue(value)) \(metric.unit) 看起來不太尋常。如果沒有打錯，直接儲存就可以。"
    }
}
