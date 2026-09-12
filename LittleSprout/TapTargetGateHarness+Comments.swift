#if DEBUG
import Foundation
import SwiftUI

/// LS-218：留言 sheet 的 harness host——從 `TapTargetGateHarness.swift` 拆出獨立檔案（同
/// `TapTargetGateHarness+Timeline.swift`／`+Push.swift` 既有先例）。
extension TapTargetGateHarness {
    /// 有留言的常態（3 則，同 `FiBvh` 稿面示範筆數＋文案）——涵蓋輸入列（欄位＋送出鈕）與
    /// 逐則留言列。`DismissableSheetHost`：`CommentsSheetView` 的 LS026 態靠
    /// `@Environment(\.dismiss)` 關閉，同 `deleteCommentConfirmationHost` 的既有理由。
    @MainActor
    static var commentsSheetHost: some View {
        commentsSheetHost(apiClient: PopulatedCommentAPIClient())
    }

    /// 空狀態（`TnxXE`）——`listComments` 固定回傳 `[]`。
    @MainActor
    static var commentsSheetEmptyHost: some View {
        commentsSheetHost(apiClient: PreviewCommentAPIClient())
    }

    /// 網路錯誤態（`dHSyh`）——`listComments` 固定拋 `AppError.network`。
    @MainActor
    static var commentsSheetNetworkErrorHost: some View {
        commentsSheetHost(apiClient: NetworkFailingCommentAPIClient())
    }

    /// merge-review R1 m3——`listComments` 成功回傳空清單（首載正常、輸入列可用），
    /// `createComment` 固定拋 LS026（目標已刪），釘住「送出失敗撞到 LS026 時只呈現終態、不
    /// 疊一層 alert」。
    @MainActor
    static var commentsSheetSendTargetGoneHost: some View {
        commentsSheetHost(apiClient: SendTargetGoneCommentAPIClient())
    }

    /// merge-review R1 m4——同 `diaryDetailRoleNotReadyHost` 既有先例（`familyStore.
    /// ownerUserID` 保持 `nil`，只用不帶 `ownerUserID:` 的 `seedMyFamilyForPreview(_:)`
    /// overload 種 `myFamily`）：驗證 `rowTapped(_:)`／`sendTapped()` guard 條件的鏡像
    /// （`isRowActionsReady`／`isSendReady`）正確把留言列與送出鈕都變成 `.disabled`，不是
    /// 冷啟動時可點但按下去沒反應的靜默 no-op。
    @MainActor
    static var commentsSheetOwnerNotReadyHost: some View {
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true)
        )
        return DismissableSheetHost {
            CommentsSheetView(
                kind: .diary, refId: UUID(), familyID: familyStore.myFamily!.id, timelineStore: .preview(),
                familyStore: familyStore, childrenStore: .preview(),
                commentAPIClient: PopulatedCommentAPIClient(), safetyAPIClient: PreviewSafetyAPIClient()
            )
        }
    }

    @MainActor
    private static func commentsSheetHost(apiClient: CommentAPIClient) -> some View {
        let userID = UUID()
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "陳家", createdBy: userID, createdAt: Date(), requireApproval: true),
            ownerUserID: userID
        )
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return DismissableSheetHost {
            CommentsSheetView(
                kind: .diary, refId: UUID(), familyID: familyStore.myFamily!.id, timelineStore: .preview(),
                familyStore: familyStore, childrenStore: childrenStore,
                commentAPIClient: apiClient, safetyAPIClient: PreviewSafetyAPIClient()
            )
        }
    }
}

/// 只給 `commentsSheetNetworkErrorHost` 用——`listComments` 固定拋網路錯誤，`createComment`
/// 不會被這個 host 呼叫到（送出鈕的功能性 UITest 走 `commentsSheetHost`）。
private final class NetworkFailingCommentAPIClient: CommentAPIClient, @unchecked Sendable {
    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {}

    func listComments(
        familyID: UUID, targetType: String, targetID: UUID, cursor: CommentsCursor?, limit: Int
    ) async throws -> [CommentRecord] {
        throw AppError.network(message: "offline")
    }

    func createComment(familyID: UUID, targetType: String, targetID: UUID, body: String) async throws -> UUID {
        throw AppError.network(message: "offline")
    }
}

/// 只給 `commentsSheetHost` 用的假 `CommentAPIClient`——`listComments` 固定回傳 3 則留言（同
/// `FiBvh` 稿面示範內容），讓 harness 走真正的 `.task { await store.loadInitial() }` 路徑而不是
/// 另外開一個「seed 好之後跳過非同步」的後門（`CommentsStore` 沒有對外暴露的 `store` 可以在
/// View 建構後才注入種子資料，這個假 client 是最小可行的替代方案）。`createComment` 回傳新
/// `UUID()`，harness 本身不驗證送出後的結果（那是 `CommentsSheetUITests` 的範圍）。
private final class PopulatedCommentAPIClient: CommentAPIClient, @unchecked Sendable {
    private let authorID = UUID()

    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {}

    func listComments(
        familyID: UUID, targetType: String, targetID: UUID, cursor: CommentsCursor?, limit: Int
    ) async throws -> [CommentRecord] {
        guard cursor == nil else { return [] }
        let now = Date()
        return [
            CommentRecord(
                id: UUID(), authorID: authorID, authorDisplayName: "陳志明",
                body: "已經在收拾了，明天見！", createdAt: now
            ),
            CommentRecord(
                id: UUID(), authorID: UUID(), authorDisplayName: "林美玲",
                body: "看起來玩得好開心～下次約一起去！", createdAt: now.addingTimeInterval(-3600)
            ),
            CommentRecord(
                id: UUID(), authorID: authorID, authorDisplayName: "陳志明",
                body: "好可愛喔！挖沙工具記得多帶幾個，上次那組被沖到海裡了 😄",
                createdAt: now.addingTimeInterval(-7200)
            )
        ]
    }

    func createComment(familyID: UUID, targetType: String, targetID: UUID, body: String) async throws -> UUID {
        UUID()
    }
}

/// 只給 `commentsSheetSendTargetGoneHost` 用（merge-review R1 m3）——`listComments` 回傳空
/// 清單（讓輸入列一開始就可用），`createComment` 固定拋 `AppError.rejected` LS026，模擬「送出時
/// 才發現目標已刪」。
private final class SendTargetGoneCommentAPIClient: CommentAPIClient, @unchecked Sendable {
    func setCommentDeleted(commentID: UUID, deleted: Bool) async throws {}

    func listComments(
        familyID: UUID, targetType: String, targetID: UUID, cursor: CommentsCursor?, limit: Int
    ) async throws -> [CommentRecord] { [] }

    func createComment(familyID: UUID, targetType: String, targetID: UUID, body: String) async throws -> UUID {
        throw AppError.rejected(message: "target 已刪除", code: LSErrorCode.targetFamilyMismatch.rawValue)
    }
}
#endif
