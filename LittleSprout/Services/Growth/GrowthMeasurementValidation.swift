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
