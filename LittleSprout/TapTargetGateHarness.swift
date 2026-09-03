#if DEBUG
import AVFoundation
import SwiftUI
import UIKit

/// LS-95：≥44pt 點擊目標機械 gate 的畫面掛載點。
///
/// XCUITest 啟動 app 時沒辦法「憑空」跳過登入／建立家庭流程直接開到某個 Feature 畫面——
/// `tap-target-check.sh`（透過 `TapTargetGateTests`）用 `LS_TAP_TARGET_GATE_SCREEN` 這個
/// launch environment 變數（值見 `TapTargetGateScreenName`）告訴 app「這次啟動請直接顯示這個
/// 畫面」，用既有 `#Preview` 已經在用的同一組 `.preview()` mock store 建構，不打真網路、不需要
/// `Config/Secrets.xcconfig`。
///
/// 只有 `TapTargetGateTests`／`TapTargetGateSelfTests` 會設這個環境變數，一般使用者啟動 app
/// 永遠讀不到、走 `LittleSproutApp.body` 原本的 `RootView` 路徑。整支 `#if DEBUG` 圍住——依賴
/// 的 `.preview()` 系列本身就只在 DEBUG 存在（見 `PreviewAuthService.swift` 等），Release
/// build 不會編到這支檔案，也不可能被誤觸發。
///
/// 新增受測畫面：`TapTargetGateScreenName` 加一個 case，這裡的 `hostView` 補對應分支。
enum TapTargetGateHarness {
    static var activeScreen: TapTargetGateScreenName? {
        ProcessInfo.processInfo.environment["LS_TAP_TARGET_GATE_SCREEN"]
            .flatMap(TapTargetGateScreenName.init(rawValue:))
    }

    @MainActor
    @ViewBuilder
    static func hostView(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .otpVerification:
            NavigationStack {
                // cooldownSeconds: 0：一開畫面 `canResend` 就是 true，重寄 Button 立刻顯示
                // （見 `OTPVerificationView.init` 文件註解），不必真的等 60 秒冷卻。
                OTPVerificationView(email: "grandma@example.com", authStore: .preview(), cooldownSeconds: 0) {}
            }
        case .settings:
            NavigationStack {
                // merge-review R1 M1(b)：「邀請家人」列只在 `familyStore.myFamily != nil` 才
                // 渲染（LS-107）——`.preview(withFamily:)` 同步餵一個家庭狀態，那顆列才會被量到
                // （見 `FamilyStore.seedMyFamilyForPreview`／`PreviewFamilyAPIClient.swift`）。
                SettingsView(
                    authStore: .preview(),
                    familyStore: .preview(withFamily: Family(
                        id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                    )),
                    childrenStore: .preview(),
                    timelineStore: .preview()
                )
            }
        case .diaryEditor:
            diaryEditorHost
        case .timelineDefaultState:
            timelineDefaultStateHost
        case .sectionTabView:
            sectionTabViewHost
        case .sectionTabViewWithDiary:
            sectionTabViewWithDiaryHost
        case .diaryCardVideoBadges:
            diaryCardVideoBadgesHost
        case .selfTestTooSmall:
            // `.frame()` 直接接在 `Button(_:action:)` 後面不可靠：純文字、預設樣式的按鈕，
            // accessibility／hit-test frame 實測仍貼著文字本身的天然大小，不會被外層 `.frame`
            // 撐大或縮小（LS-95 開發期間實測撞到——這正是本票要抓的那種「視覺／版面大小」跟
            // 「真正 hit-test 大小」對不上的落差）。改用 `.contentShape(Rectangle())` 明確把
            // hit-test 形狀鎖定成 `.frame` 給的矩形，樣本大小才會是可控、決定性的數字。
            Button(action: noop) {
                Text("小按鈕")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
        case .selfTestGood:
            Button(action: noop) {
                Text("好按鈕")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        case .selfTestPaddingOutsideButton:
            // 刻意重現 LS-17 QA1 的原始寫法（PR #148 R1 F1 修正前）：padding 掛在 Button 外層
            // 的 VStack，不是掛在 Button 的 label closure 裡再接 `.contentShape(Rectangle())`
            // ——視覺上按鈕四周看起來有一大圈空白，但那圈空白不參與 hit test，實際可點區域仍
            // 只有內容本身的大小（20×20，用同一招 `.contentShape` 鎖定成決定性數字）。
            VStack {
                Button(action: noop) {
                    Text("小按鈕")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
            }
            .padding(20)
        }
    }

    /// merge-review R1 M5：初始態不需要任何 seeding——`PreviewDiaryAPIClient`／
    /// `PreviewMediaUploadService`（`Support/PreviewDiaryAPIClient.swift`，同樣是
    /// `#Preview` 在用的假 client）＋既有 `ChildrenStore.preview()`，跟 `DiaryEditorView`
    /// 自己的 `#Preview("空白")` 是同一組建構。拆成獨立 computed var（不是留在 `hostView`
    /// 的 switch 本體裡）：merge LS-125／LS-126 後兩個新 case 加起來讓 `hostView` 超過
    /// SwiftLint `function_body_length` 上限，各自的建構邏輯本來就跟其他 case 無關，抽出
    /// 去不影響行為，只是把長度還給界限內。
    @MainActor
    @ViewBuilder
    private static var diaryEditorHost: some View {
        NavigationStack {
            DiaryEditorView(
                familyID: UUID(), diaryAPIClient: PreviewDiaryAPIClient(),
                mediaUploadService: PreviewMediaUploadService(), childrenStore: .preview()
            )
        }
    }

    /// `.preview()` 三個 store 皆空狀態（無家庭／無寶貝／無 feed），`ChildFilterBar`
    /// 因 `childrenStore.activeChildren.isEmpty` 不會渲染，畫面上唯一的可點元件就是
    /// Header 的「新增回憶」建立鈕——不需要任何 seed 資料就有代表性。merge LS-125：
    /// `TimelineView` 現在直接持有 `diaryAPIClient`／`mediaUploadService`（同
    /// `diaryEditorHost` 用的假 client），才能建構。理由同上，拆成獨立 computed var。
    @MainActor
    @ViewBuilder
    private static var timelineDefaultStateHost: some View {
        NavigationStack {
            TimelineView(
                familyStore: .preview(), childrenStore: .preview(), timelineStore: .preview(),
                diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService()
            )
        }
    }

    /// LS-136：`SectionTabView`（compact，四分頁）＋`SectionTabBar`。同 `.settings` 案例的家庭
    /// seeding 理由——`AuthenticatedRootView` 走 `familyStore.myFamily != nil` 分支才會顯示
    /// tab bar，不然會落在 `ForkView` 三岔路。`.environment(\.horizontalSizeClass, .compact)`
    /// 同 `RootView.swift` `#Preview("Compact")` 既有寫法，強制走 `SectionTabView` 而非
    /// `SectionSplitView`（不依賴模擬器實際 size class）。
    @MainActor
    @ViewBuilder
    private static var sectionTabViewHost: some View {
        AuthenticatedRootView(
            authStore: .preview(),
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(),
            diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService()
        )
        .environment(\.horizontalSizeClass, .compact)
    }

    /// merge-review R1 M1 回歸測試用：同 `sectionTabViewHost`，但 `timelineStore` 額外
    /// `seedForPreview` 一筆日記——時間軸空狀態沒有任何可點的卡片，無法真的 push 進
    /// `DiaryDetailView`（`SectionTabBarPushRegressionTests` 需要）。body 用可獨立辨識的
    /// 字串（不會跟畫面上其他文字撞名），UI test 直接點它進入詳情頁。
    /// `@ViewBuilder` body 不能塞裸的 void 陳述式（`timelineStore.seedForPreview(...)` 這種呼叫
    /// 會被 `buildExpression` 硬吃成一個 View 表達式而編譯失敗）——seeding 副作用抽到這支普通
    /// 函式裡，`@ViewBuilder` var 那邊只留一個單純的 `let` 賦值。
    @MainActor
    private static func seededTimelineStore() -> TimelineStore {
        let store = TimelineStore.preview()
        store.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: UUID(), occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "LS-136 R2 回歸測試日記", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0
                ))
            )
        ])
        return store
    }

    /// 刻意**不** seed 家庭（跟 `sectionTabViewHost` 不同）：`TimelineView` 掛在畫面上就會跑
    /// `.task(id: familyStore.myFamily?.id)`／`.task(id: TimelineRefreshKey(...))`，兩支都會
    /// 呼叫 `timelineStore.refresh(...)`——若 `myFamily` 非 nil，會真的打
    /// `PreviewTimelineAPIClient.fetchTimelinePointers`（固定回傳 `[]`）蓋掉上面 seed 的那一筆，
    /// 畫面打回「還沒有回憶」空狀態（實測撞到）。`myFamily == nil` 時兩支 `.task` 的
    /// `guard let familyID = familyStore.myFamily?.id else { return }` 直接短路，seed 的資料
    /// 才留得住。這個變體本來就只為了讓卡片可點、push 進 `DiaryDetailView`，不需要家庭狀態。
    @MainActor
    @ViewBuilder
    private static var sectionTabViewWithDiaryHost: some View {
        let timelineStore = seededTimelineStore()
        AuthenticatedRootView(
            authStore: .preview(), familyStore: .preview(),
            childrenStore: .preview(), timelineStore: timelineStore,
            diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService()
        )
        .environment(\.horizontalSizeClass, .compact)
    }

    /// merge-review `443ec21a` §3：`DiaryCardVideoBadgeGeometryTests` 量真實 frame 用——
    /// `timelineStore` 帶一個立即回傳固定時長（12:34，兩位數分鐘，取「分鐘數兩位會再寬」的
    /// 最壞情況，見 reviewer 原文）的 `durationLoader`，讓無縮圖列的 `.task` 一啟動就能把
    /// `videoDurations` 填成「影片 12:34」，不必等真的（會失敗的）`AVURLAsset` 探測。3 張
    /// 附照＝`totalPhotoCount`，不觸發「還有 N 張」暗蓋，3 個徽章狀態（無徽章／縮圖影片
    /// 恆「影片」／無縮圖舊影片「影片 12:34」）同時可見、可測。
    ///
    /// QA R4（`a356f033` FAIL）：三個 `MediaContent` 原本 `signedURL` 不是 `nil` 就是假的
    /// `https://example.com/...`——`AsyncImage` 永遠載不到真圖，一律落回
    /// `thumbnailImage(_:)` 的 `Color.lsSurface2`（無固有尺寸的純色，任何 `.frame` 給多寬就是
    /// 多寬，怎麼裁都不會露餡）。這正是 R2／R3 兩輪模擬器像素量測從未踩到「真圖片撐爆格子」
    /// 這個缺陷的原因——真人上傳的直式縮圖（235×512，長寬比 ~1:2.18）用
    /// `.scaledToFill()` 蓋滿正方提案時，理想尺寸遠大於那個正方形，見
    /// `DiaryCardView.previewThumbnail` 的 `.clipped()` 修復註解。改用
    /// `makeTestImageURL(width:height:color:)`（runtime 產生、寫進
    /// `FileManager.default.temporaryDirectory`，不依賴任何外部路徑或網路，CI／其他 checkout
    /// 都能重現）產生三張長寬比刻意不同、且都跟 `MediaContent` 宣告的 `width`／`height`（或
    /// `thumbWidth`／`thumbHeight`）成比例一致的**真實可解碼圖片**——橫向照片（4:3）、直式
    /// 縮圖影片（~1:2.18，QA 踩到的那個比例）、直式舊影片（~1:2.17）——`AsyncImage` 這次會
    /// 真的走 `.success` 分支，才能量到 `.clipped()` 修復是否生效。
    @MainActor
    @ViewBuilder
    private static var diaryCardVideoBadgesHost: some View {
        let legacyVideoID = UUID()
        let thumbnailVideoID = UUID()
        NavigationStack {
            ScrollView {
                DiaryCardView(
                    content: DiaryContent(
                        body: "點擊目標 gate 幾何量測樣本", entryDate: Date(),
                        previewPhotos: [
                            MediaContent(
                                id: UUID(), type: .photo, width: 800, height: 600,
                                thumbWidth: nil, thumbHeight: nil, storagePath: "f/photo.jpg",
                                isThumbnail: false,
                                signedURL: makeTestImageURL(
                                    width: 200, height: 150,
                                    color: UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
                                )
                            ),
                            MediaContent(
                                id: thumbnailVideoID, type: .video, width: 884, height: 1920,
                                thumbWidth: 235, thumbHeight: 512, storagePath: "f/thumb-video.mov",
                                isThumbnail: true,
                                signedURL: makeTestImageURL(
                                    width: 118, height: 256,
                                    color: UIColor(red: 0.0, green: 0.4, blue: 1.0, alpha: 1.0)
                                )
                            ),
                            MediaContent(
                                id: legacyVideoID, type: .video, width: 884, height: 1920,
                                thumbWidth: nil, thumbHeight: nil, storagePath: "f/legacy-video.mov",
                                isThumbnail: false,
                                signedURL: makeTestImageURL(
                                    width: 221, height: 480,
                                    color: UIColor(red: 0.0, green: 0.8, blue: 0.2, alpha: 1.0)
                                )
                            )
                        ],
                        totalPhotoCount: 3
                    ),
                    taggedChildren: [],
                    timelineStore: .preview(durationLoader: { _ in CMTime(seconds: 754, preferredTimescale: 600) }),
                    // merge-review R3（`add3f2c1` m1）：`DiaryCardView` 不再自己量寬，改由
                    // 呼叫端（正式路徑是 `TimelineView.feedContentWidth`）算好傳入——這裡比照
                    // 單欄（`columns == 1`）情境算一次同款的值（螢幕寬扣 `screenPad`＋
                    // `insetCard` 各兩份），跟 `TimelineView` 的算法一致。
                    previewRowWidth: UIScreen.main.bounds.width
                        - 2 * AppSpacing.screenPad - 2 * AppSpacing.insetCard
                )
                .padding(.horizontal, AppSpacing.screenPad)
            }
        }
    }

    /// QA R4（`a356f033`）：在 app 的 temporary directory 即時畫一張純色 JPEG、回傳
    /// `file://` URL 給 `AsyncImage` 載——不依賴 scratchpad 或任何寫死的機器路徑，同一份
    /// harness 程式碼在任何 checkout／CI runner 上都能重現同一組長寬比。純色即可：這裡要測的
    /// 是「`.scaledToFill()` 蓋滿＋裁切是否正確」，不是圖片內容本身；用不同顏色純粹方便肉眼
    /// 截圖辨識哪一格對應哪一張測試圖。
    private static func makeTestImageURL(width: Int, height: Int, color: UIColor) -> URL {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ls130-tap-target-gate-\(UUID().uuidString)", conformingTo: .jpeg)
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: url)
        }
        return url
    }

    private static func noop() {}
}
#endif
