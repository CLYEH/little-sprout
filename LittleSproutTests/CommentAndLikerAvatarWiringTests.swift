import XCTest

/// LS-345 R2（merge-review R1 M1）：留言作者／自己／按讚者的頭像從「一律沖印佔位」改成真的
/// 顯示——沒有 ViewInspector 測不到 `CommentsSheetView`／`LikersListSheet` 實際渲染出的樹
/// （同 `GrowthDetailViewerGatingRegressionTests`／`ProfileAvatarDisplayRegressionTests` 文件
/// 註解點名的既有理由），這裡用原始碼文字守衛三個呼叫點。`ProfilePrintChip` 本身「真的把
/// avatarURL 餵給 AsyncImage」由 `ProfilePrintChipAvatarRenderingTests`（像素渲染比對）另外
/// 守，這裡只守「呼叫端有沒有把值轉手進去」。
final class CommentAndLikerAvatarWiringTests: XCTestCase {
    private func sourceText(relativePath: String, file: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// mutation：把 `commentRow` 的 `ProfilePrintChip(...)` 改回不帶 `avatarURL:`，這支測試
    /// 會抓到——留言作者的頭像會永遠是佔位圖，即使 `author_avatar_url` 已經有值。
    func test_commentRow_passesAuthorAvatarURL() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Content/CommentsSheetView+List.swift")

        XCTAssertTrue(
            source.contains("avatarURL: familyStore.avatarDisplayURL(rawValue: comment.authorAvatarURL)"),
            "commentRow 要把 comment.authorAvatarURL 經 avatarDisplayURL(rawValue:) 轉手給 ProfilePrintChip"
        )
    }

    /// mutation：把 `footer` 的 `ProfilePrintChip(...)` 改回不帶 `avatarURL:`，這支測試會
    /// 抓到——輸入列自己的頭像會永遠是佔位圖。
    func test_footer_passesOwnAvatarURL() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Content/CommentsSheetView+Footer.swift")

        XCTAssertTrue(
            source.contains("avatarURL: familyStore.avatarDisplayURL(rawValue: familyStore.myProfile?.avatarURL)"),
            "footer 要把 familyStore.myProfile?.avatarURL 經 avatarDisplayURL(rawValue:) 轉手給 ProfilePrintChip"
        )
    }

    /// mutation：把 `sendTapped()` 樂觀插入的 `authorAvatarURL:` 拿掉（改回固定 nil），這支
    /// 測試會抓到——送出當下自己那一列的頭像不會立刻顯示，要等重開 sheet 才會出現。
    func test_sendTapped_passesOwnAvatarURLToOptimisticInsert() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Content/CommentsSheetView+Footer.swift")

        XCTAssertTrue(
            source.contains("authorAvatarURL: authorAvatarURL"),
            "sendTapped() 要把查到的 authorAvatarURL 轉手給 store.send(...)，樂觀插入那一列才有頭像"
        )
        XCTAssertTrue(
            source.contains("let authorAvatarURL = viewerMember?.avatarURL"),
            "authorAvatarURL 要從 familyStore.members 查自己那一筆——同 authorDisplayName 既有慣例"
        )
    }

    /// mutation：把 `likerRow` 的 `ProfilePrintChip(...)` 改回不帶 `avatarURL:`，這支測試會
    /// 抓到——按讚名單的頭像會永遠是佔位圖，即使 reactor 的 avatar_url 已經有值。
    func test_likerRow_passesReactorAvatarURL() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Timeline/LikersListSheet.swift")

        XCTAssertTrue(
            source.contains("avatarURL: familyStore.avatarDisplayURL(rawValue: reactor.avatarURL)"),
            "likerRow 要把 reactor.avatarURL 經 avatarDisplayURL(rawValue:) 轉手給 ProfilePrintChip"
        )
    }

    /// mutation：把 `SupabaseTimelineAPIClient.reactors(...)` 的 `.select(...)` 改回不取
    /// `avatar_url`，這支測試會抓到——`ReactorRow.avatarURL` 永遠解不到值（`TimelineModelsTests`
    /// 的解碼測試餵的是合成 JSON，不會被這個 mutation 影響，需要這支另外守住 select 字串本身）。
    func test_reactorsSelect_includesAvatarURL() throws {
        let source = try sourceText(
            relativePath: "LittleSprout/Services/Timeline/SupabaseTimelineAPIClient.swift"
        )

        XCTAssertTrue(
            source.contains(".select(\"user_id, profiles(display_name, avatar_url)\")"),
            "reactors(...) 的 .select(...) 要一併取 avatar_url，否則 ReactorRow.avatarURL 永遠是 nil"
        )
    }
}
