import Foundation

/// 時間軸「第一次吃到〇〇」卡片（LS-383，`cmp/Card Food First` `SBzKx`；板 05 `SLjde`／深色 `QGdHY`／
/// AX3 `CgmBD`）上的文字與「哪些區塊要畫」——抽成純函式，`FoodFirstCardCopyTests` 不建 View 就能鎖住
/// 四態（無照片／有照片／只有日期／同日並列）的區塊組合與逐字文案。
enum FoodFirstCardCopy {
    /// 卡片由上而下可能出現的區塊（稿 `SBzKx` 子節點順序：Head Row → Note → Photo → Book Row → Sign-off
    /// Rule＋Signature）。Head Row 裡的反應列另計（`reaction`）；沒有互動列（v1 無留言／愛心，範圍 4）。
    enum Section: Equatable {
        case head
        case note
        case photo
        case bookRow
        case signature
    }

    /// 「第一次吃到〇〇」（稿 `FGNkY`）。
    static func headline(foodName: String) -> String { "第一次吃到\(foodName)" }

    /// Book Row「收進〇〇的飲食圖鑑 · 〈類別〉」（稿 `KkzBk`；〇〇＝`children.name`、類別＝
    /// `food_catalog.category` 中文，Notes `jQp2m`）。
    static func bookRowLabel(childName: String, category: FoodCategory) -> String {
        "收進\(childName)的飲食圖鑑 · \(category.displayName)"
    }

    /// 一句話：`nil`／純空白＝沒寫（Note 整段隱藏）。
    static func note(_ record: ChildFoodRecord) -> String? {
        guard let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        return note
    }

    /// 反應列（稿 `OZHA9`，沒選整列隱藏）：沿用 LS-380 的 `FoodReaction`（臉＋文字的單一來源）；CHECK 之外的值
    /// 同樣隱藏，不讓英文代碼露出。
    static func reaction(_ record: ChildFoodRecord) -> FoodReaction? {
        record.reaction.flatMap(FoodReaction.init(rawValue:))
    }

    /// 這張卡要畫哪些區塊。照片只看組裝結果有沒有讀到（`content.photo`），不看 `media_id`：照片已被軟刪
    /// 時 `media_id` 還在、但讀不到，卡片不留一塊空白。
    static func sections(for content: FoodFirstContent) -> [Section] {
        var sections: [Section] = [.head]
        if note(content.record) != nil { sections.append(.note) }
        if content.photo != nil { sections.append(.photo) }
        sections += [.bookRow, .signature]
        return sections
    }

    /// 署名「暱稱 · 年齡」拆成三段（稿 Signature `Wqlnp`：Who Group `J4XBHw` 600 主墨／Age Group `M4SYe`＝Sep `c1erNo`
    /// ＋Age `aL05o` regular 次墨，Signature 與 Age Group 的 gap 都是 `$sp-tight`）：「·」獨立成 Sep 節點、
    /// 與年齡之間由 View 的 HStack 補 `$sp-tight`。年齡＝第一次吃那天（Notes `vMFj3`），字元規則走
    /// `FoodRecordDetailCopy.imprintCaption`（＝`AlbumSignatureFormatter.segment`，UTC）——與記錄詳情壓印行、
    /// 時間軸照片卡同源；Sep 逐字＝`AlbumSignatureFormatter.separator`（U+0020 · U+00A0，與稿 `c1erNo` 一致）。
    struct Signature: Equatable {
        let name: String
        let separator: String
        let age: String
    }

    static func signature(child: Child, firstTriedOn: Date) -> Signature {
        let segment = FoodRecordDetailCopy.imprintCaption(child: child, firstTriedOn: firstTriedOn)
        let age = String(segment.dropFirst(child.name.count + AlbumSignatureFormatter.separator.count))
        return Signature(name: child.name, separator: AlbumSignatureFormatter.separator, age: age)
    }
}
