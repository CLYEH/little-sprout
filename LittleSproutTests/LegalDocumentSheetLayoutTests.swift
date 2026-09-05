@testable import LittleSprout
import XCTest

/// LS-191 merge-review R2 M2（`8305338b`）：iPad Slide Over／分割視窗（呈現容器可窄至
/// ≈320pt，專案 universal 且未設 `UIRequiresFullScreen`，是可達狀態）下，原本固定
/// `.frame(width: 520)`＋固定 87.5 內距會讓內容被容器邊界裁掉（例如標題「使用條款」被裁成
/// 「用條款」）。`LegalDocumentSheet.iPadCardAdaptivePadding` 把「容器寬度 → 內距」抽成純
/// 函式，這裡直接單元測試，不需要真的在 iPad 上拖出 Slide Over（simctl 無法腳本化分割
/// 視窗——這是本輪唯一能自動化重現「320pt 窄容器」情境的方式，320 這個數字本身就是 reviewer
/// R2 finding 用的等比例 proxy 寬度）。
final class LegalDocumentSheetLayoutTests: XCTestCase {
    private let maxPadding: CGFloat = 87.5
    private let minContentWidth: CGFloat = 345
    private let minPadding: CGFloat = 24

    private func padding(for width: CGFloat) -> CGFloat {
        LegalDocumentSheet.iPadCardAdaptivePadding(
            containerWidth: width, maxPadding: maxPadding, minContentWidth: minContentWidth, minPadding: minPadding
        )
    }

    /// R3 定案的一般情況（Notes `W0Umr`）：容器＝設計稿卡寬 520 時，內距必須是稿面訂的
    /// 87.5，不多不少——這是 R1／R2 兩輪已經用 XCUITest 釘住的數字，這裡從純函式角度再釘一次。
    func test_fullWidth520_usesDesignPadding87_5() {
        XCTAssertEqual(padding(for: 520), 87.5)
        XCTAssertEqual(520 - 2 * padding(for: 520), 345, "內容欄必須是 345，與 iPhone 版一致")
    }

    /// merge-review R2 M2 finding 本身引用的窄容器數字：320pt（iPad Slide Over 等比例
    /// proxy）——內距應降到下限 24，內容欄跟著收縮到 272，而不是維持 87.5 導致內容被容器
    /// 邊界裁掉。
    func test_narrowContainer320_clampsToMinPadding_contentNeverExceedsContainer() {
        let result = padding(for: 320)
        XCTAssertEqual(result, 24, "320pt 容器應降到內距下限 24（reviewer R2 807855dc M2 建議值）")
        let content = 320 - 2 * result
        XCTAssertEqual(content, 272)
        // merge-review R3 N1（`889164c6`）：`content + 2×result` 代回 `content` 的定義後恆等於
        // 320，不論 `result` 是什麼都成立，測不出真正的業務邏輯——改成直接斷言
        // `2×內距 ≤ 容器寬`（等價於「內容欄不得為負」），這條才會隨 `iPadCardAdaptivePadding`
        // 的實際輸出改變而變動。
        XCTAssertLessThanOrEqual(2 * result, 320, "2×內距不得超出容器寬度——這是不裁字的根本保證")
    }

    /// 邊界值：393（＝ 345 內容欄 ＋ 24×2 下限內距）——剛好是「內距開始從 87.5 往下降」的
    /// 臨界點，(393-345)/2 = 24 恰好等於下限，兩種計算路徑（封頂與保底）在這裡交會。
    func test_boundaryWidth393_paddingIsExactlyMinPadding() {
        XCTAssertEqual(padding(for: 393), 24)
    }

    /// 介於 393 與 520 之間的容器寬度，內距應該線性內插（不是只有「87.5」或「24」兩檔）——
    /// 對應真實 iPad 分割視窗（例如 1/2 或 2/3 分割）介於全螢幕與 Slide Over 之間的中間態。
    func test_interpolatedWidth450_computesProportionalPadding() {
        XCTAssertEqual(padding(for: 450), 52.5)
    }

    /// 核心不變量（property-based 精神）：對任意合理容器寬度，回傳的內距永遠落在
    /// `[minPadding, maxPadding]` 之間，且「內容欄（＝ `width - 2×padding`）」永遠不是負數
    /// ——這才是 M2「不裁字」真正要保證的性質，不是只釘幾個特定數字。
    ///
    /// merge-review R3 N1（`889164c6`）：原本這裡還有兩條 `(width - 2*result) + 2*result`
    /// 代回原式後恆等於 `width` 的斷言，不論 `iPadCardAdaptivePadding` 回傳什麼都成立、抓不到
    /// 任何邏輯錯誤（mutation 下限改 0 或上限改 100 都不會讓那兩條變紅），已移除；下面
    /// `2 * result <= width` 才是真的會隨業務邏輯改變而變動的斷言。**下界前提**（誠實記錄，
    /// 不誇稱「數學上任何寬度都不可能裁字」）：這條在 `width < 2 × minPadding`（48pt）時會
    /// 失敗——`max(minPadding, computed)` 的下限保底本身就會讓內距之和超過一個小於 48pt 的
    /// 容器寬。實務上不會有 48pt 的 sheet／裝置寬，這裡的測試範圍（280–700）刻意避開這個
    /// 不切實際的區間，不代表函式對任意輸入都成立。
    func test_paddingAlwaysWithinBounds_contentNeverExceedsContainer() {
        for width in stride(from: CGFloat(280), through: 700, by: 5) {
            let result = padding(for: width)
            XCTAssertGreaterThanOrEqual(result, minPadding, "width=\(width)")
            XCTAssertLessThanOrEqual(result, maxPadding, "width=\(width)")
            XCTAssertLessThanOrEqual(2 * result, width, "內容欄不得為負數：width=\(width)")
        }
    }

    /// 容器比 520 更寬（理論上 `.frame(maxWidth: 520)` 已經封頂，這裡量的是純函式本身在輸入
    /// 超過設計寬度時是否仍守規矩——不應該把內距撐大超過稿面定案的 87.5）。
    func test_widerThanDesignWidth_stillCapsAtMaxPadding() {
        XCTAssertEqual(padding(for: 900), maxPadding)
    }
}
