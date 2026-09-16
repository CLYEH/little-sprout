import Foundation

/// AX3 文案折行機械保證（LS-312，Notes `h5BNyi`→`w7bLF`／`TZOSC`）：末行 ≥3 個字元，不得出現
/// 1～2 字元孤字。這是 Notes 明確承認「對任意孩子名字都不可能穩定成立」之後，仍然要求 ios-dev
/// 端沿用的**同一條**驗收——用貪婪逐字折行（每行固定字元數）模擬固定寬度容器的中文排版，是
/// 真實 `Text` 版面的近似模型（不含斷詞／字寬差異），但跟稿面本身採用的判準是同一套算法，足以
/// 機械驗證票文範圍內用到的示範孩子名字（見 `GrowthEmptyStateBodyTests`）。
enum TextWrapGuarantee {
    /// 依固定每行字元數貪婪折行，回傳每一行的字元數（不含實際文字內容）。
    static func wrappedLineLengths(_ text: String, charactersPerLine: Int) -> [Int] {
        guard charactersPerLine > 0, !text.isEmpty else { return [] }
        let characters = Array(text)
        var lengths: [Int] = []
        var index = 0
        while index < characters.count {
            let end = min(index + charactersPerLine, characters.count)
            lengths.append(end - index)
            index = end
        }
        return lengths
    }

    /// 末行字元數 ≥ `minimumLastLineCharacters`（預設 3，Notes `TZOSC` 的機械保證）。
    static func lastLineHasNoOrphan(
        _ text: String, charactersPerLine: Int, minimumLastLineCharacters: Int = 3
    ) -> Bool {
        guard let last = wrappedLineLengths(text, charactersPerLine: charactersPerLine).last else { return true }
        return last >= minimumLastLineCharacters
    }
}
