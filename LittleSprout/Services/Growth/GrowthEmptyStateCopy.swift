import Foundation

/// 04 空狀態文案（Notes `C8yU4O`／`TZOSC`）——iPhone／深色／AX3 三板逐字相同內容（AX3 只換
/// 折行寬度，不換文字）。抽成純函式讓 `GrowthEmptyStateCopyTests` 能不建 View 就驗證
/// `TextWrapGuarantee` 機械保證。
enum GrowthEmptyStateCopy {
    static let title = "這張紙還沒有記錄"

    static func body(childName: String) -> String {
        "新增第一筆身高、體重或頭圍，就能看見\(childName)的成長曲線。"
    }

    /// Notes `TZOSC`：AX3 文字框 160pt／`$fs-meta` AX3 33pt ＝ 每行最多 4 個中文字——與
    /// `TextWrapGuarantee.lastLineHasNoOrphan` 搭配使用的每行字元數。
    static let ax3CharactersPerLine = 4
}
