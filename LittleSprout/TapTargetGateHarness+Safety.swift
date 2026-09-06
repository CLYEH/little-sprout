#if DEBUG
import SwiftUI

/// LS-189：內容操作表（05／05b／05d／05e）、封鎖名單（06）、檢舉收件匣（07／07b）、日記詳情
/// 「⋯」入口的 harness host——從 `TapTargetGateHarness.swift` 拆出獨立檔案，同
/// `TapTargetGateHarness+Settings.swift`／`+Albums.swift` 從主檔拆分的既有先例（該檔已經很
/// 接近 SwiftLint `file_length` 上限）。
extension TapTargetGateHarness {
    /// `hostView(for:)` 對這八個新 case 的分派——見該函式呼叫端註解（`function_body_length`
    /// 上限）。純粹的「畫面名稱 → View」1:1 dispatch，跟主檔那支 switch 同一種形狀。
    @MainActor
    @ViewBuilder
    static func safetyHostView(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .contentActionsSheet: contentActionsSheetHost
        case .reportReasonSheet: reportReasonSheetHost
        case .blockConfirmSheet: blockConfirmSheetHost
        case .ownerRemoveContentConfirmSheet: ownerRemoveContentConfirmSheetHost
        case .blockList: blockListHost
        case .reportInbox: reportInboxHost
        case .reportInboxEmpty: reportInboxEmptyHost
        case .diaryDetail: diaryDetailHost
        case .diaryDetailOwnContent: diaryDetailOwnContentHost
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
                )
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
                diaryAPIClient: PreviewDiaryAPIClient()
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
                diaryAPIClient: PreviewDiaryAPIClient()
            )
        }
    }
}
#endif
