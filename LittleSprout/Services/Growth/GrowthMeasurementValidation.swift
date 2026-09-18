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

    /// 「超出合理範圍」的軟性提醒——刻意用固定絕對門檻，不是依年齡換算的百分位（票文「不做：
    /// 參考帶」已排除百分位計算，這裡是單純的手誤攔截：使用者常見的打字失誤是漏打小數點
    /// （例如想輸入 18.0 卻打成 180），門檻選在「絕大多數孩子的合理量測範圍」之上、又低於
    /// 「漏小數點常見錯誤值」，三項各自獨立檢查（同 `GrowthCurve` 三條曲線互不影響的既有
    /// 精神），只回傳**第一個**超出範圍的項目（Range Warning Slot 只有一個插槽，不會同時列
    /// 三條警語）——依身高／體重／頭圍的檢查順序，同表單欄位的視覺順序一致。
    static func rangeWarning(heightCm: Double?, weightKg: Double?, headCm: Double?) -> String? {
        if let heightCm, heightCm > heightWarningThreshold {
            return warningMessage(metric: .height, value: heightCm, adjective: "高")
        }
        if let weightKg, weightKg > weightWarningThreshold {
            return warningMessage(metric: .weight, value: weightKg, adjective: "重")
        }
        if let headCm, headCm > headWarningThreshold {
            return warningMessage(metric: .head, value: headCm, adjective: "大")
        }
        return nil
    }

    private static let heightWarningThreshold = 130.0
    private static let weightWarningThreshold = 40.0
    private static let headWarningThreshold = 60.0

    /// Notes `hQpxd` 例句：「身高 180.0 cm 比同齡孩子高很多。如果沒有打錯，直接儲存就可以。」
    private static func warningMessage(metric: GrowthMetric, value: Double, adjective: String) -> String {
        "\(metric.label) \(metric.formattedValue(value)) \(metric.unit) 比同齡孩子\(adjective)很多。如果沒有打錯，直接儲存就可以。"
    }
}
