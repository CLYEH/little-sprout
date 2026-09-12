import Foundation

/// LS-216（互動列：愛心反應／留言計數）用到的 `TimelineStore` 動作——拆成獨立檔案，理由同
/// `FamilyStore+Members.swift` 檔頭註解：主檔 `TimelineStore.swift` 逼近 SwiftLint
/// `file_length`（400 行）上限，R4（merge-review R3 F1／F2）修法會再加行數，才觸發拆檔。狀態
/// 本身（`reactionStates`／`commentCounts`／`togglingReactionKeys`）仍宣告在主檔（Swift
/// extension 不能加 stored property），這裡只放操作它們的方法。
extension TimelineStore {
    /// LS-216：`InteractionRow` 讀目前的愛心狀態——沒有紀錄（`get_reaction_counts` 沒有回、
    /// 或還沒載入過）一律視為 `.zero`，見 `reactionStates` 文件註解。
    func reactionState(forKey key: String) -> ReactionState {
        reactionStates[key] ?? .zero
    }

    /// LS-216：`InteractionRow` 讀目前的留言計數——見 `commentCounts` 文件註解（目前恆為 0，
    /// 待 LS-218 用 `setCommentCount` 同步真正筆數）。
    func commentCount(forKey key: String) -> Int {
        commentCounts[key] ?? 0
    }

    /// LS-218 之後：留言 sheet 讀到真正的留言筆數時呼叫，同步互動列顯示的計數（見
    /// `commentCounts` 文件註解「計數同步來自互動列」）。
    func setCommentCount(_ count: Int, forKey key: String) {
        commentCounts[key] = count
    }

    /// 切換單一 target 的愛心——樂觀更新＋失敗回滾＋連點去重（LS-216 票文 scope 2）。
    ///
    /// **連點去重**：`togglingReactionKeys` 的 `guard`／`insert` 在第一個 `await` 之前同步
    /// 完成——`@MainActor` 保證同一個 target key 的第二次呼叫不可能在第一次呼叫的 suspension
    /// point 之前插隊執行，第二次呼叫的 `guard` 會直接失敗、安靜忽略（不排隊、不報錯，票文
    /// 「in-flight 期間忽略」選項）。
    ///
    /// **樂觀更新**：本地先切換 `reactedByMe`＋±1 計數；RPC 回傳的 `reactedByMe` 是切換後的
    /// 權威值，用來校正本地猜測（正常情況下兩者一致，只有極罕見的跨裝置同時切換才會不一致，
    /// 這裡用伺服器的回答收斂 `reactedByMe`，不做進一步的計數重查——計數本身的些微誤差會在
    /// 下一次 `refresh`／`loadMore` 自然校正）。RPC 失敗時整個 `ReactionState` 回滾到呼叫前
    /// 的快照，並把 `AppError.map(error)` 往外拋，呼叫端（`InteractionRow`）決定怎麼顯示
    /// （既有 `.alert` 語彙，同 `DiaryDetailView.playVideo` 的既有寫法）。
    func toggleReaction(kind: FeedKind, refId: UUID, familyID: UUID) async throws {
        let key = TimelineEntry.id(kind: kind, refId: refId)
        guard !togglingReactionKeys.contains(key) else { return }
        togglingReactionKeys.insert(key)
        defer { togglingReactionKeys.remove(key) }
        let previous = reactionStates[key] ?? .zero
        let optimistic = previous.reactedByMe
            ? ReactionState(count: max(0, previous.count - 1), reactedByMe: false)
            : ReactionState(count: previous.count + 1, reactedByMe: true)
        reactionStates[key] = optimistic
        do {
            let reactedByMe = try await apiClient.toggleReaction(
                familyID: familyID, targetType: kind.rawValue, targetID: refId
            )
            reactionStates[key]?.reactedByMe = reactedByMe
        } catch {
            reactionStates[key] = previous
            throw AppError.map(error)
        }
    }

    /// 按讚名單 sheet 用——純轉發，不快取（票文：純資訊列表，開啟當下重查一次即可，見
    /// `LikersListSheet`）。
    func reactors(kind: FeedKind, refId: UUID, familyID: UUID) async throws -> [ReactorRow] {
        try await apiClient.reactors(familyID: familyID, targetType: kind.rawValue, targetID: refId)
    }

    /// LS-216 R2（merge-review R1 M1／M2）：一頁（或 `loadMore` 新追加的一段）內容組好之後，
    /// 依 `kind` 分組批次呼叫 `get_reaction_counts`——同一頁最多 3 次呼叫（一種 kind 一次，見
    /// `TimelineAPIClient.reactionCounts` 文件註解），三種 kind 用 `withTaskGroup` 平行發出
    /// （同 `TimelineContentAssembler.fetchContentMaps` 既有理由：序列 await 沒必要拉長總等待
    /// 時間），結果收集齊後**一次**寫回 `reactionStates`。
    ///
    /// **呼叫端 `await` 這支，但不擋使用者看到內容**：`@Observable` 屬性在賦值當下就通知觀察者
    /// （不必等外層 `async` 函式整個返回）——呼叫端（`refresh`／`loadMore`）已經在呼叫這支
    /// 之前就把 `entries`／`refreshState`／`loadMoreState` 寫成 `.success`，畫面此刻已經能顯示
    /// 時間軸本身；這支仍在跑的期間，愛心一律顯示 `reactionStates` 尚未覆寫前的預設 `.zero`。
    /// 寫回前重驗 `expectedGeneration == generation`：若飛行期間又有更新的 `refresh`（世代號
    /// 已前進），`entries` 已換過基底，這批結果安靜丟棄，不覆蓋新世代可能已更新的值。R4：
    /// 查詢失敗的 kind 保留舊值不寫回，查成功但缺席才寫 `.zero`（見下方 `succeededKinds`）。
    func loadReactionCounts(for newEntries: [TimelineEntry], familyID: UUID, expectedGeneration: Int) async {
        let idsByKind = Dictionary(grouping: newEntries, by: \.kind).mapValues { $0.map(\.refId) }
        guard !idsByKind.isEmpty else { return }
        let apiClient = self.apiClient
        var merged: [String: ReactionState] = [:]
        var succeededKinds: Set<FeedKind> = []
        await withTaskGroup(of: (FeedKind, [ReactionCountRow])?.self) { group in
            for (kind, targetIDs) in idsByKind {
                group.addTask {
                    (try? await apiClient.reactionCounts(
                        familyID: familyID, targetType: kind.rawValue, targetIDs: targetIDs
                    )).map { (kind, $0) }
                }
            }
            for await case let (kind, rows)? in group {
                succeededKinds.insert(kind)
                for row in rows {
                    merged[TimelineEntry.id(kind: kind, refId: row.targetID)] =
                        ReactionState(count: row.reactionCount, reactedByMe: row.reactedByMe)
                }
            }
        }
        guard expectedGeneration == generation else { return }
        // R4（merge-review R3 F1／F2）：只對查成功的 kind 寫回（缺席一律 `.zero`，失敗整批
        // 跳過保留舊值）；`togglingReactionKeys` 內的 key 也跳過——避免歸零飛行中的樂觀更新。
        for (kind, targetID) in idsByKind.flatMap({ kind, ids in ids.map { (kind, $0) } })
        where succeededKinds.contains(kind) {
            let key = TimelineEntry.id(kind: kind, refId: targetID)
            guard !togglingReactionKeys.contains(key) else { continue }
            reactionStates[key] = merged[key] ?? .zero
        }
    }

    #if DEBUG
    /// LS-216：`TapTargetGateHarness`／UITest／單元測試灌指定 target 的愛心狀態，不必真的
    /// 跑一次 `get_reaction_counts`——同 `TimelineStore.seedForPreview(entries:)` 的角色與
    /// 圍欄理由（見該方法）。
    @MainActor
    func seedReactionState(_ state: ReactionState, forKey key: String) {
        reactionStates[key] = state
    }
    #endif
}
