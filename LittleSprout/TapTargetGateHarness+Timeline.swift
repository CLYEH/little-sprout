#if DEBUG
import SwiftUI

/// LS-216：時間軸卡片互動列（`InteractionRow`）的 harness host，從 `TapTargetGateHarness.swift`
/// 拆出獨立檔案——加完這支之後那支檔案超過 SwiftLint `file_length`／`type_body_length` 上限，
/// 理由同 `TapTargetGateHarness+Albums.swift` 拆分的既有先例（見該檔文件註解）。
///
/// 兩支 host 都不能標 `private`（Swift 的 `private` 以檔案為界，跨檔案的 `extension` 存取
/// 不到）——同 `TapTargetGateHarness+Albums.swift` 拆分後的既有作法，改用預設（internal）
/// 存取層級，範圍仍只在本 module 內，`TapTargetGateHarness.hostView(for:)` 才呼叫得到。
extension TapTargetGateHarness {
    /// LS-216：`InteractionRow`——三種卡片（日記／相簿／照片）各一筆，`已按讚`／`未按讚`／
    /// `計數 0` 三種愛心狀態都覆蓋到，同 `seededTimelineStore`（`TapTargetGateHarness.swift`）
    /// 拆出 plain function 的既有理由（`@ViewBuilder` body 不能塞裸的 seeding 呼叫）。
    @MainActor
    static func seededInteractionRowTimelineStore() -> TimelineStore {
        let store = TimelineStore.preview()
        let diaryID = UUID()
        let albumID = UUID()
        let mediaID = UUID()
        store.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "LS-216 互動列量測樣本：日記卡", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0
                ))
            ),
            TimelineEntry(
                kind: .album, refId: albumID, occurredAt: Date().addingTimeInterval(-60), childIds: [],
                content: .album(AlbumContent(title: "LS-216 互動列量測樣本：相簿卡", cover: nil))
            ),
            TimelineEntry(
                kind: .media, refId: mediaID, occurredAt: Date().addingTimeInterval(-120), childIds: [],
                content: .media(MediaContent(
                    id: mediaID, type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "f/photo.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                ))
            )
        ])
        // 未按讚（日記卡）／已按讚（相簿卡）——兩態的 Like Toggle／Count Zone 都要 ≥44pt；
        // 照片卡故意留計數 0（未反應，`seedReactionState` 不呼叫，`reactionState(forKey:)`
        // 缺席一律回 `.zero`），驗證 Count Zone 在 `disabled` 狀態下熱區仍不縮小。
        store.seedReactionState(
            ReactionState(count: 3, reactedByMe: false), forKey: TimelineEntry.id(kind: .diary, refId: diaryID)
        )
        store.seedReactionState(
            ReactionState(count: 5, reactedByMe: true), forKey: TimelineEntry.id(kind: .album, refId: albumID)
        )
        return store
    }

    /// 刻意**不** seed 家庭——同 `sectionTabViewWithDiaryHost`（`TapTargetGateHarness.swift`）
    /// 文件註解點名的既有陷阱（seed 了會讓 `TimelineView` 的 `.task` 真的打
    /// `PreviewTimelineAPIClient.fetchTimelinePointers` 蓋掉種好的 `entries`）。
    /// `InteractionRow` 需要的 `familyID` 由 `seedForPreview(entries:familyID:)` 直接種進
    /// `timelineStore` 本身，不依賴 `familyStore.myFamily`。
    ///
    /// **不能用 `let timelineStore = seededInteractionRowTimelineStore()` 直接塞進
    /// `@ViewBuilder static var`**（LS-216 R1 曾這樣寫，模擬器互動實測發現的真實缺陷，不是
    /// 猜測）：`interactionRowHost` 是計算屬性，每次被存取都重新執行整個函式本體——
    /// `TapTargetGateHarness.hostView(for:)` 被 `LittleSproutApp` 的 `WindowGroup` 內容
    /// closure 呼叫，而點擊 `InteractionRow` 的 Like Toggle 觸發 `timelineStore.reactionStates`
    /// 這個 `@Observable` 屬性變化時，會導致這整條路徑重新求值——若 `timelineStore` 只是
    /// `let`（不是有身分保存機制的儲存），每次重新求值都會呼叫
    /// `seededInteractionRowTimelineStore()` 產生**全新**的 `TimelineStore` 物件與全新的
    /// `InteractionRow`／`NavigationStack` 值樹身分，把剛做的樂觀更新與 `InteractionRow`
    /// 自己的 `@State`（`isToggling` 等）一起蓋掉、退回原始種子值——**實測現象**：連續點擊
    /// Like Toggle，畫面上的計數／已按讚態永遠彈回種子值，看起來像「點了沒反應」。正式路徑
    /// （`LittleSproutApp`）沒有這個問題，因為 `timelineStore` 在那裡是 `@State`（建立一次、
    /// 跨重繪存活），這裡改用同一招——包一層有 `@State` 的 `View` struct，讓
    /// `seededInteractionRowTimelineStore()` 只在這個 `View` 身分第一次出現時執行一次。
    @MainActor
    static var interactionRowHost: some View {
        InteractionRowHost()
    }
}

/// 見 `TapTargetGateHarness.interactionRowHost` 文件註解——`@State` 的初始值運算式只在這個
/// `View` 身分第一次出現時執行一次，讓 `timelineStore` 在後續重繪（例如 `InteractionRow`
/// 點擊觸發的 `@Observable` 變化）之間維持同一個物件參照，不會被重新種子化。
private struct InteractionRowHost: View {
    @State private var timelineStore = TapTargetGateHarness.seededInteractionRowTimelineStore()

    var body: some View {
        NavigationStack {
            TimelineView(
                familyStore: .preview(), childrenStore: .preview(), timelineStore: timelineStore,
                diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService(),
                safetyAPIClient: PreviewSafetyAPIClient(), commentAPIClient: PreviewCommentAPIClient()
            )
        }
    }
}
#endif
