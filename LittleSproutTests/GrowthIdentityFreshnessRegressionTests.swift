import XCTest

/// LS-312 R3（merge-review R2 M1-a，orchestrator 裁決 `8cf0114c`）：R2 把 `GrowthStore` 重建鎖在
/// `childID` 上（修 R1 M1）之後，順帶把 `childName`／`childBirthday` 的新鮮度也鎖掉了——
/// `ChildrenStore.updateChild()` 成功後 `reloadChildrenList()` 換出新的 `Child`（同一個 `id`，
/// 名字／生日已改），`ChildGrowthDetailView` 拿到的 `child` 參數是新的，但畫面卻繼續讀
/// `growthStore.childName`／`growthStore.childBirthday`（store 建立當下寫死一次、`needsRebuild`
/// 同一個孩子不重建，之後永遠不會更新）——Identity Header 的名字／年齡、空狀態文案的孩子名、
/// 曲線的月齡軸全部停在編輯前的舊值。
///
/// 修法：Identity Header／`GrowthChartCardView` 的 `childName:`／曲線的 `curvePoints(for:
/// birthday:)` 全部改吃 `child.name`／`child.birthday`（呼叫端重繪時 `child` 本身就是新值，
/// 不需要 store 跟著換）。`growthStore` 之後只負責 `records`／`loadState`。
///
/// 沒有 ViewInspector 測不到 `body` 實際渲染出的 `Text` 內容（同 `GrowthDetailTitleRegressionTests`
/// ／`ChildRowNavigationRegressionTests` 文件註解點名的既有理由），這裡用原始碼文字守衛：
/// mutation 把這幾處改回讀 `growthStore.childName`／`growthStore.childBirthday`（R2 的寫法），
/// 這支測試會抓到。
///
/// **LS-345**：同一份「Identity Header 讀新鮮 `child`」的機制，補上頭像那一格——原本
/// `identityHeader()` 完全沒有把任何 `avatarURL` 傳給 `ChildAvatarView`（不是新鮮度問題，是
/// 從沒接線），換頭像存檔後畫面永遠停在縮寫圓。見下面兩支新測試。
final class GrowthIdentityFreshnessRegressionTests: XCTestCase {
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

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// mutation：把 `identityHeader()` 內任何一處改回 `growthStore.childName`／
    /// `growthStore.childBirthday`（R2 的舊寫法），這支測試轉紅——編輯存檔後（同一
    /// `child.id`）Identity Header 的名字／年齡會停在舊值。
    func test_identityHeader_readsChildNotStaleGrowthStoreSnapshot() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        XCTAssertTrue(
            source.contains("ChildAvatarView(name: child.name, size: 64, avatarURL: avatarURL)"),
            "Identity Header 頭像縮寫應該讀 child.name（新鮮值），不是 growthStore.childName（建立當下寫死的舊快照）"
        )
        XCTAssertTrue(
            source.contains("Text(child.name)"),
            "Identity Header 名字應該讀 child.name"
        )
        XCTAssertTrue(
            source.contains("BirthdayFormat.ageDescription(birthday: child.birthday)"),
            "Identity Header 年齡字串應該讀 child.birthday，不是 growthStore.childBirthday"
        )
    }

    /// LS-345：Identity Header 存檔換頭像後仍顯示縮寫圓——上傳成功但畫面沒接
    /// `avatarURL`（`ChildAvatarView(name: child.name, size: 64)` 完全沒帶這個參數）。
    /// mutation：把 `identityHeader()` 的 `ChildAvatarView(...)` 改回不帶 `avatarURL:`（LS-345
    /// 之前的舊寫法），這支測試會抓到。
    func test_identityHeader_passesAvatarURLToChildAvatarView() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        XCTAssertTrue(
            source.contains("ChildAvatarView(name: child.name, size: 64, avatarURL: avatarURL)"),
            "Identity Header 的 ChildAvatarView 要帶 avatarURL:，否則存檔換頭像後畫面仍停在縮寫圓"
        )
    }

    /// LS-345：呼叫端 `childDetail(for:)` 若不再傳 `avatarURL: childrenStore.avatarURL(for:
    /// child)`（例如漏傳、或傳固定 nil），這支測試會抓到——同 `GrowthDetailViewerGatingRegressionTests
    /// .test_childrenManagementView_passesCanManageChildrenFromStore` 既有先例。
    func test_childrenManagementView_passesAvatarURLFromStore() throws {
        let source = try sourceText(
            relativePath: "LittleSprout/Features/Children/ChildrenManagementView+Detail.swift"
        )

        XCTAssertTrue(
            source.contains("avatarURL: childrenStore.avatarURL(for: child)"),
            "childDetail(for:) 要把 childrenStore.avatarURL(for: child) 轉手給 ChildGrowthDetailView，"
                + "跟列表列（ChildrenManagementView）讀的是同一份簽名 URL 快取，換頭像存檔後才會反映新值"
        )
    }

    /// mutation：把 `GrowthChartCardView(` 呼叫的 `childName:` 改回 `growthStore.childName`
    /// （compact／regular 任一處），這支測試轉紅——04 空狀態文案（含曲線卡的孩子名）會停在舊值。
    func test_growthChartCardViewChildName_readsChildOnBothLayouts_notStaleSnapshot() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        let expectedChartCall = "isEmptyState: growthStore.isEmpty, childName: child.name,"
        XCTAssertEqual(
            occurrenceCount(of: expectedChartCall, in: source), 2,
            "GrowthChartCardView 的 childName: 應該在 compactLayout／regularLayout 兩處都讀 child.name"
                + "（04 空狀態文案含孩子名，不能停在編輯前的舊名字）"
        )
        XCTAssertFalse(
            source.contains("childName: growthStore.childName"),
            "GrowthChartCardView 不該再吃 growthStore.childName——那是 store 建立當下寫死的舊快照"
        )
    }

    /// mutation：把曲線的 `curvePoints(for: selectedMetric, birthday: child.birthday)` 改回
    /// `growthStore.curvePoints(for: selectedMetric)`（讀 store 內部寫死的 `childBirthday`），
    /// 這支測試轉紅——使用者把打錯的生日改對之後，曲線 x 軸的月齡刻度仍照舊生日算，要 pop 再
    /// push 才會對。
    func test_curvePoints_takesChildBirthdayParameter_notStoreSnapshot() throws {
        let viewSource = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")
        let storeSource = try sourceText(relativePath: "LittleSprout/Services/Growth/GrowthStore.swift")

        let expectedCall = "growthStore.curvePoints(for: selectedMetric, birthday: child.birthday)"
        XCTAssertEqual(
            occurrenceCount(of: expectedCall, in: viewSource),
            2,
            "曲線卡兩處呼叫（compact／regular）都該把 child.birthday 當月齡基準傳進去，"
                + "不能靠 GrowthStore 內部寫死的 childBirthday"
        )
        XCTAssertTrue(
            storeSource.contains(
                "func curvePoints(for metric: GrowthMetric, birthday: Date) -> [GrowthCurve.CurvePoint]"
            ),
            "GrowthStore.curvePoints(for:) 應該收一個 birthday 參數，不是讀 self.childBirthday"
        )
        XCTAssertTrue(
            storeSource.contains("GrowthCurve.curvePoints(for: metric, records: records, birthday: birthday)"),
            "GrowthStore.curvePoints(for:birthday:) 應該把呼叫端傳進來的 birthday 轉呼叫給 GrowthCurve，"
                + "不是用 self.childBirthday"
        )
    }
}
