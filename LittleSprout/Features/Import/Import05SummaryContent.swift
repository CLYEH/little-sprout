import Foundation

/// LS-373：05 完成摘要的統計列與「寶貝沒有指定成功」段落內容——純函式，`Import05SummaryView`
/// 只照這份渲染，數字契約與逐字文案在這裡鎖住、由 `Import05SummaryContentTests` 驗。
///
/// 稿面來源：`design/littlesprout.pen` Notes「LS-349 完成摘要補齊」段（`x5SHq`）——統計卡
/// `T5gSe`、Marking Section `JKCKd`、LS044 `yGn3W`、狀態 `x73Dy6`／`XG9yu`。
struct Import05SummaryContent: Equatable {
    /// 統計卡頂層列（D1／D2）。數字契約（`T5gSe`）：頂層列的 `count` 加總＝開始匯入時的總數
    /// （成功＋沒有成功＋沒有加入）。寶貝沒有指定成功的照片已經上傳成功、算在成功數裡，所以
    /// 只能是 `.succeeded` 底下的子數字，不得另起一個頂層列（那樣總數會多算一次）。
    enum StatRow: Hashable {
        case succeeded(count: Int, unassignedBabyCount: Int)
        case failed(count: Int)
        case dropped(count: Int)

        var count: Int {
            switch self {
            case .succeeded(let count, _), .failed(let count), .dropped(let count): count
            }
        }
    }

    /// 「這 N 張的寶貝沒有指定成功」段落（D3／D4）。
    struct MarkingSection: Equatable {
        let header: String
        /// 一組一個 `VStack`、一句一個 `Text`：05 一組兩句；05b（同批有寶貝已移除）分「發生
        /// 什麼／怎麼辦」兩組；全部都是 LS044 時一組兩句且沒有按鈕。
        let noteGroups: [[String]]
        /// 「補上寶貝（N）」的 N——只算可重試的群；0＝不出現按鈕。
        let fillableCount: Int
    }

    let statRows: [StatRow]
    let markingSection: MarkingSection?

    init(
        completedCount: Int, failedCount: Int, droppedCount: Int,
        markingFailedCount: Int, retryableMarkingFailedCount: Int
    ) {
        var rows: [StatRow] = [.succeeded(count: completedCount, unassignedBabyCount: markingFailedCount)]
        if failedCount > 0 { rows.append(.failed(count: failedCount)) }
        if droppedCount > 0 { rows.append(.dropped(count: droppedCount)) }
        statRows = rows
        markingSection = markingFailedCount > 0
            ? Self.makeMarkingSection(total: markingFailedCount, fillable: retryableMarkingFailedCount)
            : nil
    }

    /// 文案逐字照稿面 `JKCKd`／`yGn3W`（05 `w50qt`、05b `x4D0mD`）。不可重試張數＝全部−可重試
    /// （Notes `G9R27X` D4：不需要新 API）。
    private static func makeMarkingSection(total: Int, fillable: Int) -> MarkingSection {
        let removed = total - fillable
        let groups: [[String]]
        if removed == 0 {
            groups = [["照片都匯入了。", "補上寶貝不會重新上傳照片。"]]
        } else if fillable == 0 {
            groups = [["照片都匯入了。", "選的寶貝已經移除，這 \(total) 張沒辦法指定。"]]
        } else {
            groups = [
                ["照片都匯入了。", "\(removed) 張的寶貝已經移除，沒辦法指定。"],
                ["另 \(fillable) 張可以補上。", "補上寶貝不會重新上傳照片。"]
            ]
        }
        return MarkingSection(header: "這 \(total) 張的寶貝沒有指定成功", noteGroups: groups, fillableCount: fillable)
    }

    /// 成功統計底下的子列文案（D1）。
    static func unassignedBabyLine(count: Int) -> String {
        "其中 \(count) 張的寶貝沒有指定成功"
    }

    /// 「補上寶貝（N）」鈕的 label 與停用態（D3／D5，Notes `x73Dy6`／`XG9yu`）：請求進行中整顆
    /// 停用、label 改「正在補上寶貝…」；「寶貝」與「（N）」之間放 U+2060，（N）不單獨斷行。
    static func fillBabiesButton(count: Int, isInFlight: Bool) -> (title: String, isDisabled: Bool) {
        isInFlight ? ("正在補上寶貝…", true) : ("補上寶貝\u{2060}（\(count)）", false)
    }
}
