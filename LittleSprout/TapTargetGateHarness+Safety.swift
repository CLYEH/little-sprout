#if DEBUG
import SwiftUI

/// LS-189：內容操作表（05／05b／05d／05e）、封鎖名單（06）、檢舉收件匣（07／07b）、日記詳情
/// 「⋯」入口的 harness host——從 `TapTargetGateHarness.swift` 拆出獨立檔案，同
/// `TapTargetGateHarness+Settings.swift`／`+Albums.swift` 從主檔拆分的既有先例（該檔已經很
/// 接近 SwiftLint `file_length` 上限）。
extension TapTargetGateHarness {
    /// `hostView(for:)` 對這十二個新 case 的分派——見該函式呼叫端註解（`function_body_length`
    /// 上限）。純粹的「畫面名稱 → View」1:1 dispatch，跟主檔那支 switch 同一種形狀。
    @MainActor
    @ViewBuilder
    // swiftlint:disable:next cyclomatic_complexity
    static func safetyHostView(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .contentActionsSheet: contentActionsSheetHost
        case .reportReasonSheet: reportReasonSheetHost
        case .reportReasonSheetTargetGone: reportReasonSheetTargetGoneHost
        case .blockConfirmSheet: blockConfirmSheetHost
        case .ownerRemoveContentConfirmSheet: ownerRemoveContentConfirmSheetHost
        case .blockList: blockListHost
        case .reportInbox: reportInboxHost
        case .reportInboxEmpty: reportInboxEmptyHost
        case .reportInboxResolveError: reportInboxResolveErrorHost
        case .diaryDetail: diaryDetailHost
        case .diaryDetailOwnContent: diaryDetailOwnContentHost
        case .diaryDetailRoleNotReady: diaryDetailRoleNotReadyHost
        case .diaryDetailWithVideo: diaryDetailWithVideoHost
        default:
            // 不會發生——呼叫端（`hostView(for:)`）只在 screen 屬於這八個 case 之一時才會
            // 轉呼叫這支函式；這裡仍需要窮舉分支讓編譯器接受，`fatalError` 讓誤用立刻爆炸
            // （fail loud），不是靜默顯示空白畫面。
            fatalError("safetyHostView(for:) 收到非預期的 screen：\(screen)")
        }
    }

    /// 05 內容操作表——三動作皆顯示的示範態（同稿面 `WgbNc` 的展示假設：viewer 是家庭管理者、
    /// 且不是作者），用 `DismissableSheetHost` 頂出來（同 `deleteDiaryConfirmationHost` 既有
    /// 理由，見該檔文件註解）。
    @MainActor
    static var contentActionsSheetHost: some View {
        DismissableSheetHost {
            ContentActionsSheet(
                headline: "「今天在溜滑梯上玩得好開心。」",
                actions: [.report, .block(memberID: UUID(), memberName: "陳志明"), .removeAsOwner],
                onSelect: { _ in }
            )
        }
    }

    /// 05b 檢舉原因——`ReportReasonSheet` 本身沒有免登入即可到達的產品入口（同
    /// `deleteCommentConfirmationHost` 的既有理由：入口在 `DiaryDetailView` 的「⋯」流程裡）。
    @MainActor
    static var reportReasonSheetHost: some View {
        DismissableSheetHost {
            ReportReasonSheet(
                familyName: "陳家", familyID: UUID(), targetType: .comment, targetID: UUID(),
                safetyAPIClient: PreviewSafetyAPIClient()
            )
        }
    }

    /// 05b LS026（target 跨家庭）變體——`reportContentError` 種一個 LS026，見
    /// `TapTargetGateScreenName.reportReasonSheetTargetGone` 文件註解（LS-189 R2，merge-review
    /// R1 B4）。
    @MainActor
    static var reportReasonSheetTargetGoneHost: some View {
        DismissableSheetHost {
            ReportReasonSheet(
                familyName: "陳家", familyID: UUID(), targetType: .comment, targetID: UUID(),
                safetyAPIClient: PreviewSafetyAPIClient(
                    reportContentError: .rejected(message: "target belongs to another family", code: "LS026")
                )
            )
        }
    }

    /// 05d 封鎖確認。
    @MainActor
    static var blockConfirmSheetHost: some View {
        DismissableSheetHost {
            BlockConfirmSheet(
                familyID: UUID(), familyName: "陳家", blockedID: UUID(), memberName: "陳志明",
                safetyAPIClient: PreviewSafetyAPIClient()
            )
        }
    }

    /// 05e Owner 移除內容確認。
    @MainActor
    static var ownerRemoveContentConfirmSheetHost: some View {
        DismissableSheetHost {
            OwnerRemoveContentConfirmSheet(
                familyName: "陳家", targetType: .comment, targetID: UUID(),
                safetyAPIClient: PreviewSafetyAPIClient()
            )
        }
    }

    /// 06 封鎖名單——帶一筆封鎖紀錄，量測列與解除封鎖鈕。
    @MainActor
    static var blockListHost: some View {
        let familyStore = FamilyStore.preview(withFamily: Family(
            id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
        ))
        let blockedID = UUID()
        familyStore.seedMembersForPreview([
            FamilyMember(userID: blockedID, role: .member, displayName: "林伯伯", avatarURL: nil)
        ])
        return NavigationStack {
            BlockListView(
                familyStore: familyStore,
                safetyAPIClient: PreviewSafetyAPIClient(
                    blockedUsers: [BlockedUserRecord(blockedID: blockedID, createdAt: Date())]
                ),
                timelineStore: .preview()
            )
        }
    }

    /// 07 檢舉收件匣——帶一筆待處理檢舉，量測卡片三個動作。
    @MainActor
    static var reportInboxHost: some View {
        let familyStore = FamilyStore.preview(withFamily: Family(
            id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
        ))
        let reporterID = UUID()
        familyStore.seedMembersForPreview([
            FamilyMember(userID: reporterID, role: .member, displayName: "李阿嬤", avatarURL: nil)
        ])
        let report = ContentReportRecord(
            id: UUID(), targetType: .comment, targetID: UUID(), reporterID: reporterID, reason: "spam",
            status: "pending", createdAt: Date()
        )
        return NavigationStack {
            ReportInboxView(
                familyStore: familyStore,
                safetyAPIClient: PreviewSafetyAPIClient(
                    pendingReports: [report], reportSnippet: "「這張照片真的很醜」"
                )
            )
        }
    }

    /// 07b 檢舉收件匣·沒有待處理——空狀態變體。
    @MainActor
    static var reportInboxEmptyHost: some View {
        NavigationStack {
            ReportInboxView(
                familyStore: .preview(withFamily: Family(
                    id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                safetyAPIClient: PreviewSafetyAPIClient()
            )
        }
    }

    /// 07 檢舉收件匣·「這則沒問題」失敗——`markResolvedError` 種一個 42501，見
    /// `TapTargetGateScreenName.reportInboxResolveError` 文件註解（LS-189 R2，merge-review
    /// R1 B1）。
    @MainActor
    static var reportInboxResolveErrorHost: some View {
        let familyStore = FamilyStore.preview(withFamily: Family(
            id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
        ))
        let reporterID = UUID()
        familyStore.seedMembersForPreview([
            FamilyMember(userID: reporterID, role: .member, displayName: "李阿嬤", avatarURL: nil)
        ])
        let report = ContentReportRecord(
            id: UUID(), targetType: .comment, targetID: UUID(), reporterID: reporterID, reason: "spam",
            status: "pending", createdAt: Date()
        )
        return NavigationStack {
            ReportInboxView(
                familyStore: familyStore,
                safetyAPIClient: PreviewSafetyAPIClient(
                    pendingReports: [report], reportSnippet: "「這張照片真的很醜」",
                    // 同 `SupabaseSafetyAPIClient.markReportResolved` 真實會丟出的「0 列受影響」
                    // 情境（`userFacingMessage` 對 `.rejected` 一律回通用文案，不看這裡的
                    // `message`／`code`，見 `AppError.swift`）。
                    markResolvedError: .rejected(message: "沒有權限處理這則檢舉，或這則檢舉已經被處理", code: "no_rows_updated")
                )
            )
        }
    }

    /// `DiaryDetailView` 導覽列「⋯」入口——取代 `tap-target-exemptions.txt` 原本「需要
    /// TimelineStore 帶一篇日記與附照資料才有代表性」的具名排除（同 `.albumsDefaultState`／
    /// `.profileEdit` 等既有先例：換掉佔位／補上真互動內容後改直接註冊）。作者故意種成跟
    /// `familyStore.ownerUserID`（同步佈置的「我」）不同的另一個 uuid，才會渲染「檢舉／封鎖／
    /// 移除」三動作（`childrenStore.seedRoleForPreview(.owner)` 讓「移除」也一併可見）。
    @MainActor
    static var diaryDetailHost: some View {
        let diaryID = UUID()
        let viewerUserID = UUID()
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "陳家", createdBy: viewerUserID, createdAt: Date(), requireApproval: true),
            ownerUserID: viewerUserID
        )
        let timelineStore = TimelineStore.preview()
        timelineStore.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "今天在溜滑梯上玩得好開心。", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0
                ))
            )
        ])
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return NavigationStack {
            DiaryDetailView(
                diaryID: diaryID, timelineStore: timelineStore, childrenStore: childrenStore,
                familyStore: familyStore, safetyAPIClient: PreviewSafetyAPIClient(authorID: UUID()),
                diaryAPIClient: PreviewDiaryAPIClient(), commentAPIClient: PreviewCommentAPIClient()
            )
        }
    }

    /// 同 `diaryDetailHost`，但作者故意種成跟 `viewerUserID` 相同——`contentActions(...)` 只會
    /// 回傳 `.deleteOwn`，覆蓋「操作表『刪除』→ 既有 `DiaryDeleteConfirmationSheet`」這條分流
    /// （`ContentActionsUITests.testDiaryDetailOwnContent_...` 用這個 host）。
    @MainActor
    static var diaryDetailOwnContentHost: some View {
        let diaryID = UUID()
        let viewerUserID = UUID()
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "陳家", createdBy: viewerUserID, createdAt: Date(), requireApproval: true),
            ownerUserID: viewerUserID
        )
        let timelineStore = TimelineStore.preview()
        timelineStore.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "今天在溜滑梯上玩得好開心。", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0
                ))
            )
        ])
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return NavigationStack {
            DiaryDetailView(
                diaryID: diaryID, timelineStore: timelineStore, childrenStore: childrenStore,
                familyStore: familyStore, safetyAPIClient: PreviewSafetyAPIClient(authorID: viewerUserID),
                diaryAPIClient: PreviewDiaryAPIClient(), commentAPIClient: PreviewCommentAPIClient()
            )
        }
    }

    /// 同 `diaryDetailHost`，但**不**呼叫 `seedRoleForPreview`——`childrenStore.myRole` 維持
    /// `ChildrenStore.preview()` 預設的 nil，驗證「更多操作」在這個狀態下正確變成 disabled
    /// （LS-189 R2，merge-review R1 m2，見 `DiaryDetailView+ContentActions.isContentActionsReady`
    /// 文件註解）。
    @MainActor
    static var diaryDetailRoleNotReadyHost: some View {
        let diaryID = UUID()
        let viewerUserID = UUID()
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "陳家", createdBy: viewerUserID, createdAt: Date(), requireApproval: true),
            ownerUserID: viewerUserID
        )
        let timelineStore = TimelineStore.preview()
        timelineStore.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "今天在溜滑梯上玩得好開心。", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0
                ))
            )
        ])
        return NavigationStack {
            DiaryDetailView(
                diaryID: diaryID, timelineStore: timelineStore, childrenStore: ChildrenStore.preview(),
                familyStore: familyStore, safetyAPIClient: PreviewSafetyAPIClient(authorID: UUID()),
                diaryAPIClient: PreviewDiaryAPIClient(), commentAPIClient: PreviewCommentAPIClient()
            )
        }
    }

    /// LS-246（票文範圍 1）：同 `diaryDetailHost`，但瀑布流帶一支已經簽好名（`isPlayableVideo`
    /// 判定為可播放）的影片格——`DiaryDetailVideoUITests` 用它驗證「留言 sheet 開著時點影片」
    /// 「影片全螢幕關閉後點『⋯』」都正確併入單一 `activeSheet`（見 `DiaryDetailView` 檔頭文件
    /// 註解、`TimelineStore.preview(diaryID:video:signedURL:)`）。`durationSeconds` 直接種好
    /// （非 nil）——`TimelineStore.displayDuration` 因此不需要真的向 `signedURL` 讀
    /// `AVURLAsset`（那必定對假 URL 失敗），accessibility label 穩定顯示「影片 0:05，點兩下
    /// 播放」，不受 `loadVideoDuration` 非同步查表時序影響。`signDelayNanoseconds` 給 3 秒
    /// ——`DiaryDetailVideoUITests` 的「留言 sheet 開著時點影片」需要在「點影片、簽名回來」
    /// 之間有個穩定的窗口能再觸發留言鈕，不依賴真網路延遲的不確定時序（見該屬性文件註解）；
    /// R1 實測：`waitForExistence`／`.tap()` 這類 XCUITest 動作本身單次就可能耗費 1–1.5 秒
    /// （輪詢間隔＋IPC 往返），0.6 秒窗口太短，「點影片→確認留言鈕存在→點留言鈕」這三步
    /// 加起來就可能超過視窗、讓影片先接手；3 秒留足這整串動作的餘裕，UITest 端仍是用
    /// `waitForExistence` 而非固定 sleep 等待，不會因為機器快慢而變脆弱。
    @MainActor
    static var diaryDetailWithVideoHost: some View {
        let diaryID = UUID()
        let viewerUserID = UUID()
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "陳家", createdBy: viewerUserID, createdAt: Date(), requireApproval: true),
            ownerUserID: viewerUserID
        )
        let timelineStore = TimelineStore.preview(
            diaryID: diaryID,
            video: MediaRow(
                id: UUID(), storagePath: "f/harness-video.mov", type: .video, width: 884, height: 1920,
                thumbPath: nil, thumbWidth: nil, thumbHeight: nil, durationSeconds: 5
            ),
            signedURL: URL(string: "https://example.com/harness-video.mp4")!,
            signDelayNanoseconds: 3_000_000_000
        )
        timelineStore.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "今天在溜滑梯上玩得好開心。", entryDate: Date(), previewPhotos: [], totalPhotoCount: 1
                ))
            )
        ])
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return NavigationStack {
            DiaryDetailView(
                diaryID: diaryID, timelineStore: timelineStore, childrenStore: childrenStore,
                familyStore: familyStore, safetyAPIClient: PreviewSafetyAPIClient(authorID: UUID()),
                diaryAPIClient: PreviewDiaryAPIClient(), commentAPIClient: PreviewCommentAPIClient()
            )
        }
    }
}
#endif
