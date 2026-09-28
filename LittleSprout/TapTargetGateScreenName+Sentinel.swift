#if DEBUG
import Foundation

/// LS-304：`sentinel` 與 `TapTargetGateSentinel` 從 `TapTargetGateScreenName.swift` 拆出——
/// 主檔疊上多張票的新 case 後逼近 SwiftLint `file_length` 上限，這裡只搬這個 computed
/// property 與它專屬的資料型別，`case` 清單本身留在主檔（Swift 不允許用 extension 幫 enum
/// 加新 case）。
extension TapTargetGateScreenName {
    /// merge-review R1 B1：harness 一旦沒有真的渲染出這個畫面（環境變數鍵值走鐘、
    /// `TapTargetGateHarness.hostView(for:)` 某個 case 回傳空內容、未來啟動流程在
    /// `RootView` 之前插入攔截畫面），量測會變成「0 個元件＝0 個違規＝綠」靜默通過——
    /// reviewer 實測：把環境變數鍵名打錯，兩條產品畫面檢查照樣全綠。每個畫面在渲染成功時
    /// 必定存在的一個 accessibility 元素當 sentinel，`TapTargetMeasurement` 啟動後先斷言它
    /// 存在，斷言失敗就代表 harness 沒生效，而不是「這個畫面剛好沒有按鈕」。
    var sentinel: TapTargetGateSentinel {
        switch self {
        case .otpVerification: return .staticText("輸入驗證碼")
        case .settings: return .button("登出")
        // 同 `.settings`：「登出」列不受角色影響，一定會渲染。
        case .settingsMemberRole: return .button("登出")
        // 預設選取＝個人（`SettingsView.regularSelection` 初值），detail 欄的「個人」段落
        // 標題一定會渲染，不依賴任何 seed 資料。
        case .settingsRegular: return .staticText("個人")
        case .diaryEditor: return .staticText("寫日記")
        case .createChild: return .staticText("幫寶貝建立檔案")
        case .timelineDefaultState: return .button("新增回憶")
        // LS-343：同 `.timelineDefaultState`——窄寬度變體不受 seed 資料影響，一定會渲染。
        case .timelineHeaderNarrow390: return .button("新增回憶")
        case .timelineHeaderNarrow375: return .button("新增回憶")
        case .timelineButtonCompressionProxy: return .button(QAAccessibilityID.timelineImportPhotos)
        case .albumsDefaultState: return .button("新增相簿")
        // 不用相簿標題（`.staticText("上禮拜的動物園一日遊")`）：`AlbumSummaryCardView`
        // 整卡是 `.accessibilityElement(children: .combine)`，Caption／Signature 兩行文字
        // 被合併成一個元素，個別標題字串量不到獨立的 staticText。Header「相簿」是唯一保證
        // 獨立存在、不受相簿資料影響的文字節點（同 `.albumsDefaultState` 的既有理由）。
        case .albumsPopulatedState: return .staticText("相簿")
        case .createAlbum: return .staticText("新增相簿")
        // 「更多操作」accessibility label——owner 視角一開畫面就會渲染，不依賴使用者先點開。
        case .albumDetailOwner: return .button("更多操作")
        // 「更多」在 member 視角不渲染，改用一定會渲染的相簿標題文字當 sentinel。
        case .albumDetailMember: return .staticText("上禮拜的動物園一日遊")
        case .editAlbum: return .staticText("編輯相簿名稱")
        case .albumDetailPopulated: return .staticText("阿公阿嬤家過年")
        case .albumDetailStress: return .staticText("34 張全滿壓測")
        // 預設選中分頁＝時間軸（`AuthenticatedRootView` 的 `selection` 初值），headerRow
        // 「時間軸」一定會渲染，不依賴任何 seed 資料。
        case .sectionTabView: return .staticText("時間軸")
        // sidebar 的「時間軸」row 與 detail 預設內容的自畫標題皆為「時間軸」，`.firstMatch` 隨便
        // 取到一個即可確認渲染成功。
        case .sectionSplitView: return .staticText("時間軸")
        // 同 `.sectionSplitView`：預設選中分頁仍是時間軸，seed 的寶貝不影響首頁。
        case .sectionSplitViewWithChildren: return .staticText("時間軸")
        // 同 `.sectionTabView`：headerRow「時間軸」不受 seed 資料影響，一定會渲染。
        case .sectionTabViewWithDiary: return .staticText("時間軸")
        case .diaryCardVideoBadges: return .staticText("影片 12:34")
        // 樣本固定含至少一列失敗（見 `UploadQueueStore.previewSample`），群標題必定渲染。
        case .uploadQueueSheet: return .staticText("沒有成功")
        // 常態樣本沒有失敗群，用永遠會渲染的標題文字當 sentinel。
        case .uploadQueueSheetNormal: return .staticText("正在新增照片")
        // 自訂 nav row 標題——固定 fixture 一開畫面就渲染。
        case .importOrganizeDefault: return .staticText("整理新照片")
        // 06a banner 標題——`accessState: .limited` 固定顯示。
        case .importOrganizeLimited: return .staticText("只能看到部分照片")
        // 06b 標題——無資料依賴，一開畫面就渲染。
        case .importPermissionDenied: return .staticText("新增照片")
        // 04 大標題——固定樣本一開畫面就渲染。
        case .importProgressDefault: return .staticText("正在匯入照片")
        // 04b Alert Title——固定樣本一開畫面就渲染。
        case .importProgressCancelConfirm: return .staticText("要取消整批匯入嗎？")
        // 05 大標題——固定樣本一開畫面就渲染。
        case .importSummaryWithFailures: return .staticText("匯入完成")
        // 同 `.importSummaryWithFailures`：疊了標記失敗狀態，大標題不受影響，一樣渲染。
        case .importSummaryWithMarkingFailure: return .staticText("匯入完成")
        case .passwordSignIn: return .staticText("帳號密碼登入")
        // Doc Title——`LegalDocumentSheet` 載入完成後必定渲染，不依賴檔案實際內容。
        case .legalDocumentSheet: return .staticText("使用條款")
        case .legalDocumentNarrowContainer: return .staticText("使用條款")
        // 標題「使用條款更新」——`EULAStore.preview(shouldPresent: true)` 一開畫面就渲染。
        case .eulaConsent: return .staticText("使用條款更新")
        // Confirm Label——`ULWgY`／`WQI5d`（危險色外框鈕）的文字，harness 固定顯示。
        case .deleteDiaryConfirmation: return .button("刪除這篇日記")
        case .deleteCommentConfirmation: return .button("刪除這則留言")
        // 一開畫面 `eulaStore.shouldPresent` 已種為 true，EULA 標題必定先渲染。
        case .eulaConsentToTimelineFlow: return .staticText("使用條款更新")
        // 「給家人的私密相簿」只在淺色模式渲染（見 `WelcomeView.headSection`），跟
        // `.preview()`／harness 固定淺色（未強制 `.preferredColorScheme`）的既有假設一致；
        // 不用字標圖片（`Image`，不是 staticText）當 sentinel。
        case .welcome: return .staticText("給家人的私密相簿")
        // R2（merge-review R1 M6）：02 稿標題是「個人資料」，R1 誤寫成「顯示名稱與頭像」。
        case .profileEdit: return .staticText("個人資料")
        case .familyMembers: return .staticText("家庭成員")
        case .deleteAccountGeneralMember: return .staticText("刪除帳號")
        case .deleteAccountMustTransfer: return .staticText("需要先轉移家庭管理者身分")
        case .deleteAccountSoleMember: return .staticText("你是這個家庭唯一的成員")
        case .deleteAccountFinalConfirm: return .staticText("最後確認")
        case .deleteAccountCompleted: return .staticText("帳號已刪除")
        case .deleteAccountFailed: return .staticText("刪除過程中發生問題")
        case .deleteAccountInProgress: return .staticText("正在刪除你的帳號…")
        // Head Title——`WgbNc` 示範態固定顯示的內容預覽文字。
        case .contentActionsSheet: return .staticText("「今天在溜滑梯上玩得好開心。」")
        case .reportReasonSheet: return .button("送出")
        case .reportReasonSheetTargetGone: return .button("送出")
        case .blockConfirmSheet: return .button("封鎖這位成員")
        case .ownerRemoveContentConfirmSheet: return .button("移除這則內容")
        case .blockList: return .staticText("封鎖名單")
        case .reportInbox: return .staticText("檢舉")
        case .reportInboxEmpty: return .staticText("檢舉")
        case .reportInboxResolveError: return .staticText("檢舉")
        // `contentActionsButton` 的 accessibility label——一開畫面（日記內容已載入）就會渲染，
        // 不依賴使用者先點開操作表。
        case .diaryDetail: return .button("更多操作")
        case .diaryDetailOwnContent: return .button("更多操作")
        case .diaryDetailRoleNotReady: return .button("更多操作")
        case .diaryDetailWithVideo: return .button("更多操作")
        case .timelineInteractionRow: return .staticText("時間軸")
        case .pushPreprompt: return .button("開啟通知")
        // 同 `.settings`：「登出」列不受推播授權狀態影響，一定會渲染。
        case .settingsPushDenied: return .button("登出")
        case .settingsPushAuthorized: return .button("登出")
        // Head Title——不依賴 `list_comments` 的非同步載入是否已完成，一開畫面就渲染。
        case .commentsSheet: return .staticText("留言")
        case .commentsSheetEmpty: return .staticText("留言")
        case .commentsSheetNetworkError: return .staticText("留言")
        case .commentsSheetSendTargetGone: return .staticText("留言")
        case .commentsSheetOwnerNotReady: return .staticText("留言")
        case .growthDetailPopulated: return .staticText("陳小安")
        case .growthDetailEmpty: return .staticText("陳小軒")
        // LS-313：Cancel 鈕（body content，非系統 toolbar，見該檔文件註解）一開 sheet 就渲染。
        case .growthMeasurementForm: return .button("取消")
        // LS-313：Header 標題文字——populated／empty 兩態皆會渲染（`navigationTitle` 另外也是
        // 「成長紀錄」，但這裡指的是 body content 裡的 Header `Text`，不依賴 `records` 是否
        // 為空）。
        case .growthRecordsList: return .staticText("成長紀錄")
        case .growthRecordActionsSheet: return .button("取消")
        case .childrenManagementPopulated: return .staticText("寶貝")
        // LS-379：body 自畫的 display 標題（系統標題已由零尺寸 principal 關掉，見 `FoodBookView`）。
        case .foodBook, .foodBookDark: return .staticText("飲食圖鑑")
        case .foodBookDairy: return .staticText("吃過 1／7")
        case .foodBookViewer: return .staticText("這本圖鑑由家人記錄，你可以隨時翻看。")
        // fixture 共用的頂端標題（feed fixture 除外，見 `photoCardBabyCaptionHost` 文件註解）。
        case .photoCardBabyCaption: return .staticText("照片卡署名")
        case .diaryCardBabyCaption: return .staticText("日記卡署名")
        case .selfTestTooSmall: return .button("小按鈕")
        case .selfTestGood: return .button("好按鈕")
        case .selfTestPaddingOutsideButton: return .button("小按鈕")
        }
    }
}

/// 純資料——不依賴 XCTest／XCUIElement，兩個 target 都能編（app target 不需要用到它，但
/// `TapTargetGateScreenName` 統一放在共用檔案，簡單起見不另外拆檔）。實際查詢邏輯（怎麼從
/// `XCUIApplication` 找到對應元素）在 `LittleSproutUITests/TapTargetMeasurement.swift`。
enum TapTargetGateSentinel {
    case staticText(String)
    case button(String)

    var description: String {
        switch self {
        case .staticText(let text): return "staticText[\(text)]"
        case .button(let label): return "button[\(label)]"
        }
    }
}
#endif
