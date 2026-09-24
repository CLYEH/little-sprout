import XCTest

/// LS-313：`GrowthMeasurementFormView` 編輯既有筆＝同 sheet 帶入值（票文範圍 1「編輯既有筆＝
/// 同 sheet 帶入值」）。沒有 ViewInspector 測不到 `init` 裡對 `@State` 的初始賦值（同
/// `GrowthDetailTitleRegressionTests` 文件註解點名的既有理由），這裡用原始碼文字守衛：
/// mutation 把任一欄的回填來源改回寫死空字串／`Date()`，這支測試會抓到。
final class GrowthMeasurementPrefillRegressionTests: XCTestCase {
    private func sourceText(relativePath: String, file: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent(relativePath)
        let fullText = try String(contentsOf: sourceURL, encoding: .utf8)
        return fullText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// mutation：把任一行改成一律吃空值（例如 `_heightText = State(initialValue: "")`，不再讀
    /// `editingRecord?.heightCm`），這支測試轉紅。
    func test_init_prefillsAllFieldsFromEditingRecord() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/GrowthMeasurementFormView.swift")

        XCTAssertTrue(
            source.contains(
                "_measuredOn = State(initialValue: editingRecord.map { Self.localMidnight(from: $0.measuredOn) }"
                    + " ?? Date())"
            ),
            "日期欄要帶入既有筆的 measuredOn（換算成裝置本地時區同一組年月日，見 M1），新增時才落回今天"
        )
        XCTAssertTrue(
            source.contains("_heightText = State(initialValue: Self.text(for: editingRecord?.heightCm))"),
            "身高欄要帶入既有筆的 heightCm"
        )
        XCTAssertTrue(
            source.contains("_weightText = State(initialValue: Self.text(for: editingRecord?.weightKg))"),
            "體重欄要帶入既有筆的 weightKg"
        )
        XCTAssertTrue(
            source.contains("_headText = State(initialValue: Self.text(for: editingRecord?.headCm))"),
            "頭圍欄要帶入既有筆的 headCm"
        )
        XCTAssertTrue(
            source.contains(#"_note = State(initialValue: editingRecord?.note ?? "")"#),
            "備註欄要帶入既有筆的 note"
        )
    }

    /// mutation：把 `Self.text(for:)` 的實作改成一律回傳空字串（不管傳入什麼），這支測試轉紅
    /// ——確認回填用的是真的把 `Double` 轉成字串，不是一個永遠回傳空字串的偽實作。
    func test_textForValue_formatsWithOneDecimalPlace() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/GrowthMeasurementFormView.swift")

        XCTAssertTrue(
            source.contains(#"value.map { String(format: "%.1f", $0) } ?? """#),
            "editingRecord 帶值時要格式化成一位小數字串，nil 時才是空字串（新增態）"
        )
    }

    /// R1 merge-review m2／R2 merge-review R2-m2：驗收「範圍軟提醒不擋儲存」（品牌第 8 條）。
    /// 原本只認兩種字面寫法（`guard rangeWarning`／`rangeWarning == nil`）——重放驗證：在
    /// `submit()` 加一行 `if rangeWarning != nil { return }`，全量 1217 支測試仍 0 failures
    /// （這種寫法沒被兩個字面比對抓到）。改成抓 `submit()` 函式本體（精確從簽名到同縮排層級
    /// 的結尾大括號）完全不含 `rangeWarning` 這個識別字——合法情況下 `submit()` 只讀
    /// `GrowthMeasurementValidation.submitDecision(...)` 的回傳值，完全不需要出現
    /// `rangeWarning`，不管用什麼寫法（guard／if／三元）讀它都算違規。
    func test_submit_neverGatesOnRangeWarning() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/GrowthMeasurementFormView.swift")

        guard let signatureRange = source.range(of: "private func submit() {") else {
            return XCTFail("找不到 submit() 函式簽名，檔案可能被重新命名")
        }
        let afterSignature = source[signatureRange.upperBound...]
        guard let endRange = afterSignature.range(of: "\n    }\n") else {
            return XCTFail("找不到 submit() 函式的結尾（4 空白縮排的右大括號）")
        }
        let body = afterSignature[..<endRange.lowerBound]

        XCTAssertFalse(
            body.contains("rangeWarning"),
            "submit() 函式本體不該出現 rangeWarning 這個字面——不管用什麼寫法擋，只要讀到它就代表" +
                "拿軟性提醒做送出判斷，違反品牌第 8 條「不 disable 儲存」"
        )
    }
}
