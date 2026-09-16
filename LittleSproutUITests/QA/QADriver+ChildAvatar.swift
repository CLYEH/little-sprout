import CryptoKit
import XCTest

// MARK: - 寶貝頭像（LS-270，來源 LS-96 池項 `66d55e5d`；獨立成 extension 檔，同 QADriver+Browse.swift 慣例）
//
// 背景：QA 三次（LS-129／LS-130／LS-266）沒辦法自己做「寶貝管理 → 選寶貝 → 編輯頭像 → 儲存 →
// 回列表看刷新」這種多步驟複驗，最後一次只能採信 ios-dev 的截圖。這條情境把那段路徑寫成可重放的
// XCUITest，讓「頭像刷新」這類驗收有腳本通道。
//
// **當時記成「mobile-mcp 每次互動把模擬器重設回主畫面（WDA session reset）」是誤判**（LS-270 (b)
// 查因）：真正的原因是**票 worktree 沒有 gitignored 的 `Config/Secrets.xcconfig`**，於是 Debug build
// 的 `SupabaseClientFactory.makeClient()`（`Config/SupabaseClientFactory.swift:36`）在啟動時就撞上
// 「佔位值 `placeholder.supabase.co`」那道 `assert` → `EXC_BREAKPOINT`／`SIGTRAP` 當場死掉，
// SpringBoard 自然留在主畫面。那道 assert 只對 XCTest 行程與 tap-target gate 放行，所以
// `xcodebuild test` 一路正常、**單獨啟動 app 必死**——與 mobile-mcp 無關（實測：不經 mobile-mcp 的
// `xcrun simctl launch` 一樣死，`~/Library/Logs/DiagnosticReports/LittleSprout-*.ips` 三份堆疊皆
// 指向同一行；補上 `LS_QA_API_URL`／`LS_QA_ANON_KEY` 兩個環境變數繞過 assert 之後，mobile-mcp
// 連續四次互動全部留在 app 內）。詳見 LS-96 待辦池與本票 handoff。
//
// **為什麼自己建一個新寶貝，而不是「選列表第一個」**：本情境要斷言的是「頭像**真的**換了」——存檔後
// 列表那一列的畫面內容必須改變。fixture 只有一張 `qa-photo.jpg`，若沿用既有寶貝，第二次跑時它的頭像
// 已經就是這張圖，存檔後逐像素不變、斷言會假紅。每次建一隻帶時戳的新寶貝（縮寫圓 → 照片）才有確定的
// 前後差異；同 `publish`／`browse` 各自 seed 自己的日記的既有慣例。建檔仍是走列表的「新增寶貝」入口，
// 所以「寶貝管理 → 列表 → 編輯頁」這段導覽路徑一樣被走過。**收工會把它刪掉**（`deleteChild`，
// merge-review R1 m3）——列表是非 lazy 的 `VStack`，留著會一輪一輪累積。
//
// **選圖走真的 `PhotosPicker`**（fixture 由 `qa-e2e.sh` 先 `simctl addmedia` 進模擬器相簿），不另外做
// launch argument 注入：`publish` 已經證明這條路可驅動（`tapNewestPickerCell`），而且沿用它代表**零 app
// 端改動**——注入型 seam 得在 `EditChildView` 開一條只有測試會走的 DEBUG 路徑，反而讓真正的上傳路徑
// 沒被覆蓋到，正好是本情境要證明的那一段。差別只有一處：`EditChildView` 的 picker 是**單選**
// （`PhotosPicker(selection:matching:)`），選完自己就關，不像 `publish` 的多選還要按一次 Done。
extension QADriver {
    func runChildAvatar() async throws {
        try await ensureLoggedIn()
        try ensureFamily()
        try openChildrenTab()

        let childName = "QA avatar \(Self.stamp())"
        try createChild(named: childName)
        let row = try require(childRow(named: childName), "寶貝列表上的「\(childName)」列", timeout: 30)
        // R2 B3：先捲到看得見再量 digest——`XCUIElement.screenshot()` 只截元素 frame，被 Tab Bar 蓋住
        // 或落在畫面外時截到的是裁切結果，前後比對會假紅／假綠。
        scrollUntilHittable(row)
        let rowBefore = elementDigest(row)
        snap("children-list-before")

        try openEditPageFromRow(named: childName)
        let avatarBefore = elementDigest(try require(avatarPickerButton, "頭像欄（「換張照片」）"))
        snap("edit-before")

        try pickAvatarFromPhotoLibrary()
        try await waitUntilSnapshotChanges(
            avatarPickerButton, from: avatarBefore,
            what: "編輯頁頭像欄的本地預覽（選圖後應從縮寫圓變成照片）", timeout: 30
        )
        snap("avatar-picked")

        try require(app.buttons["儲存變更"], "儲存變更").tap()
        try require(childrenHeading, "存檔後回到寶貝列表", timeout: 60)
        // merge-review R1 m4：重啟**前**先量一次同一列，讓「同 session 沒刷新」這件事有機械紀錄。
        // 這個值等於 `rowBefore` ＝ app 缺口仍在（LS-96 `126f7201`(1)）；哪天它等於 `rowAfter`，
        // 就是把下面那段重啟換回「同 session 直接比對」嚴格版的訊號（見 relaunchAndOpenChildrenTab 註解）。
        let rowAfterSave = try require(childRow(named: childName), "存檔後列表上「\(childName)」那一列", timeout: 30)
        scrollUntilHittable(rowAfterSave)
        let rowBeforeRelaunch = elementDigest(rowAfterSave)
        snap("children-list-after-save")

        // 重新啟動再驗，理由見下面 `relaunchAndOpenChildrenTab()` 的文件註解（同一 session 內
        // 存檔後那一列不會立刻換圖，是 app 端的已知缺口，不是本情境要守的東西）。
        try await relaunchAndOpenChildrenTab()
        // 同上：比對前先讓那一列真的落在畫面內（R2 B3）。
        scrollUntilHittable(try require(childRow(named: childName), "重啟後列表上「\(childName)」那一列", timeout: 30))
        let rowAfter = try await waitUntilSnapshotChanges(
            childRow(named: childName), from: rowBefore,
            what: "重新啟動後寶貝列表上「\(childName)」那一列的頭像（應是剛存的照片，不是姓名縮寫圓）",
            timeout: 60
        )
        // LS-274：LS-273 已修同 session 存檔後不刷新的缺口，「重啟前」那一列現在應已離開存檔前的
        // 縮寫圓佔位態——換回嚴格版斷言，不再只是 attachText 訊號。
        //
        // **不比「重啟前」與「重啟後」兩個 digest 是否逐位元相同**（曾誤用 `XCTAssertEqual(rowBeforeRelaunch,
        // rowAfter, …)`，本機實測 4 輪：2 紅 2 綠，紅的兩輪 `rowBeforeRelaunch` 皆已是第三個相異值——
        // 不是停在縮寫圓、也不是原封不動變成 `rowAfter`，截圖／DIAG 重捲＋settle 皆確認頭像早已換成同一張
        // 照片，純粹是 `elementDigest` 對漸層 fixture 的 GPU 算繪雜訊敏感，逐位元雜湊全等不是穩定判準——
        // 假紅會讓下一個人誤判缺口沒修好）。改用與 `rowAfter`（`waitUntilSnapshotChanges` 內部）同一套
        // 判準：「digest 是否已不同於存檔前的 `rowBefore`（縮寫圓佔位態）」——差異夠大（縮寫文字 vs.
        // 漸層照片）時 SHA256 才是可靠訊號，且與底下 `rowAfter` 的等待條件完全一致，不需要另外比較兩個
        // 獨立擷取的照片渲染結果。mutation（`ChildAvatarView` 包回 `if let avatarURL`）下 `rowBeforeRelaunch`
        // 與 `rowBefore` 逐位元相同，這條斷言仍會紅。
        XCTAssertNotEqual(
            rowBeforeRelaunch, rowBefore,
            "重啟前那一列 digest 仍等於存檔前的縮寫圓狀態（\(rowBefore)）——LS-273 修好後同 session 存檔應立即離開佔位態"
        )
        attachText(
            """
            child=\(childName)
            row digest before          = \(rowBefore)
            row digest before relaunch = \(rowBeforeRelaunch)
            row digest after           = \(rowAfter)
            「before relaunch」＝存檔返回列表、重啟前的同一列：等於 before ⇒ 同 session 沒刷新（app 缺口
            LS-96 `126f7201`(1) 仍在）；等於 after ⇒ 缺口已修，可把重啟那段換回同 session 嚴格版。
            """,
            name: "child-row-digest"
        )
        snap("children-list-after")

        try deleteChild(named: childName)
    }

    // MARK: - 畫面元素

    /// Tab Bar 的「寶貝」分頁鈕（`SectionTabBar` 對每個 cell 套 `accessibilityLabel(section.title)`）。
    private var childrenTab: XCUIElement { app.buttons["寶貝"] }
    /// `ChildrenManagementView` 自畫的 display 標題（`headerSection`）——tab 是 button、這裡是 staticText，
    /// 兩者同字不同型別，分得開。
    private var childrenHeading: XCUIElement { app.staticTexts["寶貝"].firstMatch }
    /// `EditChildAvatarFieldContent` 整塊是單一 accessibility element，label 固定帶「的大頭貼」
    /// （`"\(name)的大頭貼，點一下可以換照片"`）——名字會變，這半句不會。
    private var avatarPickerButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "的大頭貼")).firstMatch
    }
    /// 生日欄未選時顯示「選擇生日」，選了之後是 `BirthdayFormat.displayString` 的 `y年M月d日`
    /// （固定 `zh_Hant_TW`，與模擬器語言無關）——所以用「年」當「已選」的判準。
    private var birthdayBoxUnpicked: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "選擇生日")).firstMatch
    }
    private var birthdayBoxPicked: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "年", "日")).firstMatch
    }

    /// `ChildrenManagementView.childRow` 是包著整列的 `NavigationLink`（`.buttonStyle(.plain)`），
    /// 在 a11y tree 上是一顆 button（同 `timelineDiaryCard` 的既有形狀）；`ChildAvatarView` 是
    /// `.accessibilityHidden(true)`，所以 label 就是「姓名＋年齡 pill」——用本情境自己建的唯一名字比對。
    private func childRow(named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    // MARK: - 步驟

    /// 存檔之後重啟 app，再回到寶貝分頁。
    ///
    /// **為什麼不在同一個 session 直接驗那一列**：LS-270 首跑實測（證據
    /// `.claude/evidence/LS-270/qa-e2e/child-avatar-20260914-183531/`）——上傳 200、`/object/sign/media`
    /// 200、`public.children.avatar_url` 也已寫入，但存檔返回列表後那一列**連續 90 秒**仍畫姓名縮寫圓，
    /// 期間 Storage log 完全沒有對簽名 URL 的 GET（＝`ChildrenStore.avatarURL(for:)` 回 nil，簽名結果沒
    /// 落進 `avatarSignedURLs`）；重啟 app 之後同一列立刻就是照片。也就是說「**同一 session 內存檔後
    /// 列表那一列不會立刻換圖**」是 app 端的缺口（`ChildrenStore.reloadChildrenList` →
    /// `refreshAvatarSignedURLs` 的世代守門附近），不是本情境要守的東西——已附證據記回 LS-96 待辦池另票處理。
    ///
    /// 本情境要守的是**端到端有沒有真的換成功**：選圖 → 上傳 → 寫回 → 重新取回 → 畫出來。重啟後再比對
    /// 同一列的畫面內容，證明的正是這條完整路徑，而且不會被上面那個重繪缺口綁架成長紅（長紅的情境
    /// 等於沒有情境）。等那個缺口修掉，把這段換回「存檔後直接在同一 session 比對」會是更嚴格的版本。
    /// relaunch 後畫面本來就穩定（LS-273 修好後，重啟前後同一列已經是同一張照片）——剛拍的
    /// `children-tab`（`openChildrenTab()` 那張）跟重啟前的 `children-list-after-save` 逐位元相同
    /// 是正常的。R1 曾在這裡呼叫 `resetScreenStreak()` 處理；R2 改成在 `openChildrenTab()` 自己的
    /// `snap()` 呼叫上標 `freezeCheck: false`（見該函式），效果相同但不必每個呼叫端各自記得歸零，
    /// 這裡不需要再做什麼。QA 三次 0/3 紅的根因與證據見 LS-274 comment `8f6f9061`
    /// （`children-list-after-save`→`children-tab`→`children-list-after` 三張逐位元相同）。
    private func relaunchAndOpenChildrenTab() async throws {
        app.terminate()
        launch()
        try require(timelineHeading, "重新啟動後的時間軸", timeout: 30)
        try dismissPushPrepromptIfPresent()
        try openChildrenTab()
    }

    /// 收工把本情境建的那隻寶貝刪掉（merge-review R1 m3）。
    ///
    /// `ChildrenManagementView.childrenCard` 的 `ForEach` 包在**非 lazy 的 `VStack`** 裡，列數只增不減：
    /// 每跑一次留一隻，累積到超過一屏之後 `row.tap()` 會點到畫面外、`elementDigest(row)`（只截元素 frame）
    /// 也可能兩次都截到被裁切的同一塊而假紅。共用容器確實常被他票 `db reset`，但那不是本情境控制得了的變數。
    ///
    /// 刪除走 app 自己的路徑（編輯頁 →「移除這個寶貝」→ sheet 確認，軟刪 `deleted_at`），不開測試後門；
    /// 刪不掉就大聲失敗——靜默略過等於把累積問題留給下一輪，正是這條要修的東西。跑到這裡時本情境的
    /// 斷言都已經過了，所以這裡的紅只會是「收尾刪除」本身，訊息分得開。
    private func deleteChild(named name: String) throws {
        try openEditPageFromRow(named: name)
        try tapWhenHittable(app.buttons["移除這個寶貝"], "收尾：「移除這個寶貝」（編輯頁最下方）", timeout: 20)
        try require(app.buttons["移除，30 天內可還原"], "收尾：移除確認 sheet 的確認鈕", timeout: 20).tap()
        try require(childrenHeading, "收尾：移除後回到寶貝列表", timeout: 60)
        guard childRow(named: name).waitForNonExistence(timeout: 30) else {
            attachHierarchy(reason: "cleanup-child-still-listed")
            snap("fail-cleanup")
            XCTFail(
                "收尾刪除「\(name)」之後那一列仍在寶貝列表上——每跑一次就多留一隻，"
                + "列表是非 lazy 的 VStack，累積下去會讓下一輪 tap／digest 對到畫面外的元素（merge-review R1 m3）"
            )
            throw QAFailure.screen("收尾刪除")
        }
        snap("children-list-cleaned")
    }

    /// 捲到該元素可命中為止（捲不動就提早收工，交給 `tapWhenHittable` 的斷言大聲失敗）。
    ///
    /// merge-review R2 B3：`deleteChild` 軟刪之後，寶貝列表永遠多一列「已移除的寶貝（N）」，把「新增寶貝」
    /// 主鈕推到自訂 Tab Bar（`RootView` 的 `.safeAreaInset` 膠囊）底下——reviewer 全新模擬器實跑 2/2 紅：
    /// 鈕中心 (201, 790.5) 落在 Tab Bar 的 y 782–834 內，`tap()` 打在 Tab Bar 上，建檔頁永遠不出現。
    /// 所以列表上的關鍵點擊一律先捲，而且是**捲那個 ScrollView**（對 `app` 揮可能被 Tab Bar 吃掉）。
    private func scrollUntilHittable(_ element: XCUIElement, maxSwipes: Int = 6) {
        var lastFrame = CGRect.null
        for _ in 0..<maxSwipes {
            if isTappable(element) { return }
            guard element.exists else { return }
            let frame = element.frame
            if frame == lastFrame { return }   // 捲不動了（已到底）——再揮也沒用
            lastFrame = frame
            scrollContainer.swipeUp()
        }
    }

    /// 「點得到」的判準：存在、`isHittable`，**而且點擊中心不落在 Tab Bar 膠囊的範圍內**。
    ///
    /// R3 實測（`.claude/evidence/LS-270/qa-e2e/child-avatar-20260914-210523/`）：只用 `isHittable` 不夠——
    /// 「新增寶貝」被 Tab Bar 蓋住（鈕 762–819、Tab Bar 782–834）時 `isHittable` 仍回 true，`tap()` 打在
    /// 兩顆 tab 鈕之間的空隙上（x=201 落在 112–200 與 202–290 中間），什麼都沒發生，紅在下一步。改用
    /// 幾何判準：鈕的中心必須在 Tab Bar 上緣之上。Tab Bar 只存在於 tab-root（push 之後消失），找不到就視為無遮擋。
    private func isTappable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        guard let tabBarTop = tabBarTopY else { return true }
        return element.frame.midY < tabBarTop
    }

    /// Tab Bar 膠囊的上緣；目前畫面沒有 Tab Bar（push 進編輯頁之後）就回 nil。
    ///
    /// 只認**畫面下緣四分之一內**的分頁鈕——不能單看 label：push 之後的返回鈕 label 也是「寶貝」
    /// （R3 實測：`child-avatar-20260914-210810` 的 `child-avatar-hierarchy-not-hittable.txt:17`，
    /// `BackButton` 在 y=62），拿它當上緣會讓編輯頁上的每個元素都被判成「點不到」。
    private var tabBarTopY: CGFloat? {
        let windowHeight = app.windows.firstMatch.frame.height
        guard windowHeight > 0 else { return nil }
        let bottomZone = windowHeight * 0.75
        let tops = ["時間軸", "相簿", "寶貝", "設定"]
            .map { app.buttons.matching(NSPredicate(format: "label == %@", $0)).firstMatch }
            .filter { $0.exists && $0.frame.minY > bottomZone }
            .map(\.frame.minY)
        return tops.min()
    }

    /// 內容捲動容器：畫面有 `ScrollView` 就揮它，沒有才退回整個 app。
    private var scrollContainer: XCUIElement {
        let scrollView = app.scrollViews.firstMatch
        return scrollView.exists ? scrollView : app
    }

    /// 關鍵點擊：等元素出現 → 捲到可命中 → 再點。
    ///
    /// `require()` 只驗 `exists`；SwiftUI 的元素被 Tab Bar 蓋住時 `exists` 仍是 true，`tap()` 會靜默打在
    /// 別人身上，紅在**下一步**（R2 B3 那兩次紅的訊息是「15 秒內沒等到『寶貝建檔頁』」，病灶其實在上一步的
    /// tap 落點，排查成本很高）。這裡把「點得到」變成當場的斷言，訊息直接指向病灶。
    @discardableResult
    private func tapWhenHittable(
        _ element: XCUIElement, _ what: String, timeout: TimeInterval = 15
    ) throws -> XCUIElement {
        let target = try require(element, what, timeout: timeout)
        scrollUntilHittable(target)
        guard isTappable(target) else {
            attachHierarchy(reason: "not-hittable")
            snap("fail-not-hittable")
            XCTFail(
                "\(what)存在但捲動後仍點不到（frame \(target.frame)）——多半是被 Tab Bar 膠囊蓋住"
                + "（merge-review R2 B3：「已移除的寶貝」列會把主鈕往下推）；a11y 階層與截圖已附在 xcresult"
            )
            throw QAFailure.screen(what)
        }
        target.tap()
        return target
    }

    /// LS-312：寶貝列 row 現在推「寶貝詳情」（`ChildGrowthDetailView`），`EditChildView`（09b）
    /// 從詳情頁導覽列右上「編輯」進入，不再是列本身的目的地——把「列 → 詳情 → 編輯」這段新增
    /// 的中繼步驟封裝成一支，`runChildAvatar()`／`deleteChild(named:)` 兩處呼叫端都需要，
    /// 不各自重複。
    private func openEditPageFromRow(named name: String) throws {
        try tapWhenHittable(childRow(named: name), "寶貝列表上的「\(name)」列", timeout: 30)
        try tapWhenHittable(app.buttons["編輯"], "寶貝詳情頁導覽列右上「編輯」", timeout: 30)
        try require(app.staticTexts["編輯寶貝資料"], "編輯寶貝資料頁")
    }

    private func openChildrenTab() throws {
        try require(childrenTab, "Tab Bar「寶貝」").tap()
        try require(childrenHeading, "寶貝管理頁", timeout: 20)
        // LS-282 R2：relaunch 後（`relaunchAndOpenChildrenTab()`）這張常跟重啟前最後一張
        // `children-list-after-save` 逐位元相同——LS-273 修好頭像刷新後，重啟前後同一列已是同一張
        // 照片，畫面本來就穩定不變（不是卡住）。`freezeCheck: false`，不參與卡住累計；首次進場（非
        // relaunch）呼叫同一顆函式時這張本就跟前一張（時間軸）不同，標記不影響那條路徑的偵測能力。
        snap("children-tab", freezeCheck: false)
    }

    private func createChild(named name: String) throws {
        // R2 B3：這顆主鈕在列表長一點時（尤其有「已移除的寶貝」列）會落到 Tab Bar 底下——先捲再點。
        try tapWhenHittable(app.buttons["新增寶貝"], "寶貝管理頁「新增寶貝」")
        try require(app.staticTexts["幫寶貝建立檔案"], "寶貝建檔頁")
        // 建檔頁（compact）只有一個輸入欄（姓名或暱稱）；`LabeledTextField` 沒掛 identifier，同
        // `CreateChildView` 其餘元素的明碼慣例，這裡用 firstMatch。
        let nameField = try require(app.textFields.firstMatch, "姓名或暱稱欄")
        nameField.tap()
        nameField.typeText(name)
        try pickBirthday()
        snap("create-child")
        try require(app.buttons["建立寶貝檔案"], "建立寶貝檔案").tap()
    }

    /// 生日是建檔**必填**（`CreateChildView.submit()`：`birthday == nil` 就停在「還沒選生日」），
    /// 而 `BirthdayPickerSheet` 的 binding 只有「值真的變了」才會寫回——`birthdayBinding.get` 回的是
    /// `birthday ?? defaultBirthday`，直接按「完成」而不撥輪子，`birthday` 仍是 nil。所以這裡一定要
    /// 真的撥動輪子，再用欄位文字判定有沒有成功。
    ///
    /// 不用 `adjust(toPickerWheelValue:)`：輪子上的值是月份／日期字面，en 與 zh-Hant 寫法不同
    /// （同 `tapNewestPickerCell` 踩過的語言差異），寫死任一種就綁死模擬器語言；改用 swipe＋
    /// 事後判定，語言無關。撥不動就換方向再試，3 次都不成大聲失敗（不會靜默帶著 nil 去送出，
    /// 那樣的失敗訊息會停在「還沒選生日」、看不出是驅動沒撥到輪子）。
    private func pickBirthday() throws {
        for attempt in 1...3 {
            try require(birthdayBoxUnpicked, "生日欄（顯示「選擇生日」）").tap()
            let wheel = try require(app.pickerWheels.element(boundBy: 0), "生日選擇器的滾輪", timeout: 20)
            if attempt == 1 { wheel.swipeUp() } else { wheel.swipeDown() }
            try require(app.buttons["完成"], "生日選擇器「完成」").tap()
            if birthdayBoxPicked.waitForExistence(timeout: 5) {
                snap("birthday-picked")
                return
            }
            attachText("attempt=\(attempt)：撥動滾輪＋「完成」之後生日欄仍是「選擇生日」", name: "birthday-attempts")
        }
        attachHierarchy(reason: "birthday-picker")
        snap("fail")
        XCTFail("生日選不起來：撥動滾輪並按「完成」3 次後生日欄仍顯示「選擇生日」——建檔必填生日，再按送出只會停在「還沒選生日」")
        throw QAFailure.screen("生日欄")
    }

    /// 單選 `PhotosPicker`：選到格子就自己關，沒有 Done 鈕（`publish` 的多選才要按 Done）。
    private func pickAvatarFromPhotoLibrary() throws {
        try require(avatarPickerButton, "頭像欄（點一下換照片）").tap()
        // 先等 picker 真的呈現（Cancel 鈕 identifier 固定），再挑格——同 attachFixturesFromPhotoLibrary。
        try require(app.buttons["Cancel"], "相簿選擇器（Cancel 鈕）", timeout: 20)
        try tapNewestPickerCell(kinds: ["Photo", "照片", "相片"], what: "相簿選擇器裡的照片格")
    }

    // MARK: - 「畫面內容真的變了」斷言

    /// 單一元素的畫面內容摘要。`XCUIElement.screenshot()` 只截該元素的 frame——頭像欄與列表列都是
    /// 「同樣的文字＋不同的圖」，所以摘要變了＝圖變了。`QADriver.snap` 的整頁摘要是用來抓「卡住」，
    /// 這裡相反：是用來證明「動了」。
    func elementDigest(_ element: XCUIElement) -> String {
        SHA256.hash(data: element.screenshot().pngRepresentation).map { String(format: "%02x", $0) }.joined()
    }

    /// 輪詢到該元素的畫面內容與 `before` 不同為止；逾時＝頭像沒換上去／列表沒刷新，附階層＋截圖後
    /// `XCTFail`（訊息帶兩個摘要前 12 碼，排障時看得出是「完全沒動」而不是「等的是別的元素」）。
    @discardableResult
    private func waitUntilSnapshotChanges(
        _ element: XCUIElement, from before: String, what: String, timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists {
                let latest = elementDigest(element)
                if latest != before { return latest }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        attachHierarchy(reason: "snapshot-unchanged")
        snap("fail")
        XCTFail(
            "\(what)：\(Int(timeout)) 秒內畫面內容完全沒變（SHA256 前 12 碼 \(before.prefix(12))）"
            + "——a11y 階層與截圖已附在 xcresult"
        )
        throw QAFailure.screen(what)
    }
}
