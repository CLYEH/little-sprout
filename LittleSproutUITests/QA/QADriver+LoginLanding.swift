import XCTest

// MARK: - 登入落點失敗診斷（LS-220；獨立成 extension 避免主 class body 超過 SwiftLint type_body_length）
//
// LS-217 QA R1 FAIL（Linear comment `e4863482`）修正：拆到獨立檔案（同 `RootView
// +AuthenticatedGate.swift`／`WelcomeView+Legal.swift` 既有先例）——`QADriver.swift` 加了
// 推播前置頁的判定與 `dismissPushPrepromptIfPresent()` 後超過 SwiftLint `file_length` 上限，
// 這裡純粹搬移既有程式碼，行為不變。原本這段是 `private`（僅同檔案內同型別的 extension 視同
// 可見）；搬到獨立檔案後 `QADriver.swift` 的 `assertLandedAfterLogin()` 仍要呼叫
// `landingCandidates`／`waitForAny(_:_:timeout:failureNote:hierarchyReason:)`，改成不加存取
// 修飾詞（預設 `internal`，同 target 內可見，對外仍不公開）——`genericErrorBoilerplate` 只在本檔
// 內部使用，維持 `private`。
extension QADriver {
    var landingCandidates: [(element: XCUIElement, name: String)] {
        [(timelineHeading, "時間軸"), (forkGreeting, "三岔路"), (eulaHeading, "EULA 同意頁")]
    }

    /// `waitForAny` 包一層：等不到就附 a11y 階層＋截圖＋「畫面上最像的標題」（前幾個
    /// staticTexts 的 label）再 `XCTFail`，訊息點名等的是哪些候選（不會再跟別的逾時訊息長得
    /// 一樣，LS-220）。`hierarchyReason` 由呼叫端給——同一支 helper 被登入前後兩個不同判斷點
    /// 共用，reason 若寫死會讓兩種卡住方式在 xcresult 裡長得一樣（merge-review R2 i5）。
    func waitForAny(
        _ candidates: [(element: XCUIElement, name: String)],
        _ what: String,
        timeout: TimeInterval,
        failureNote: String,
        hierarchyReason: String
    ) throws -> String {
        let landed = waitForAny(candidates, timeout: timeout)
        guard let landed else {
            attachHierarchy(reason: hierarchyReason)
            snap("fail-landing")
            let candidateNames = candidates.map(\.name).joined(separator: "／")
            XCTFail(
                "\(what)：\(Int(timeout)) 秒內\(candidateNames)都沒出現（\(failureNote)）"
                    + "——目前畫面最像的標題：\(closestScreenTitles())"
            )
            throw QAFailure.screen(what)
        }
        return landed
    }

    /// `AppError.userFacingMessage` 的通用文案（見 `Errors/AppError.swift` 五個分支）。merge-review
    /// R2 n1：原本整個排除，但 `FamilyLookupFailedView`（`eulaGate`／`familyGate` 失敗態）畫面上
    /// 就只有這句話——整個排除會讓 `closestScreenTitles` 吐空字串，改成最後一級補位、不丟掉。
    private static let genericErrorBoilerplate: Set<String> = [
        "網路連線有問題，請檢查網路連線後再試一次。",
        "這個操作沒有成功，請確認內容後再試一次。",
        "請再試一次。",
        "無法完成這個操作。",
        "伺服器發生問題，請稍後再試一次。"
    ]

    /// 失敗訊息用：畫面上最像「標題」的幾行字（LS-220：EULA 頁與「session 沒建立」的逾時訊息曾經
    /// 一模一樣，排障繞了遠路）。優先序：① `navigationBars` 的 staticTexts；② 一般 staticTexts 裡
    /// 文字區塊最高的幾個（`frame.height` 是排版後的區塊高度、不是字級——merge-review R2 n2：實測
    /// EULA 頁標題與兩行內文同高，這只是粗略排序，非可靠字級偵測）；③ 其餘依畫面樹順序補到上限；
    /// ④ loading（「正在…」開頭）與通用錯誤樣板字降到最後一級補位（merge-review R2 n1：整個排除
    /// 會讓 `FamilyLookupFailedView` 這類畫面吐空字串，降到最後一級才能兼顧「優先真標題」與「保證
    /// 輸出不為空」）。
    private func closestScreenTitles(limit: Int = 6) -> String {
        func isBoilerplate(_ label: String) -> Bool {
            label.hasPrefix("正在") || Self.genericErrorBoilerplate.contains(label)
        }
        let navTitles = app.navigationBars.staticTexts.allElementsBoundByIndex
            .map(\.label).filter { !$0.isEmpty }
        let onScreenTexts = app.staticTexts.allElementsBoundByIndex.filter { !$0.label.isEmpty }
        let normalTexts = onScreenTexts.filter { !isBoilerplate($0.label) }
        let boilerplateTexts = onScreenTexts.filter { isBoilerplate($0.label) }
        let byHeadingSize = normalTexts.sorted { $0.frame.height > $1.frame.height }.map(\.label)
        let byDocumentOrder = normalTexts.map(\.label)
        let boilerplateFallback = boilerplateTexts.map(\.label)

        var seen = Set<String>()
        var picked: [String] = []
        for label in navTitles + byHeadingSize + byDocumentOrder + boilerplateFallback where picked.count < limit {
            guard seen.insert(label).inserted else { continue }
            picked.append(label)
        }
        return picked.isEmpty ? "（畫面上沒有文字元素）" : picked.joined(separator: "、")
    }
}
