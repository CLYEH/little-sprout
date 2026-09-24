#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `GrowthAPIClient`——不打真網路
/// （同 `PreviewChildAPIClient` 的角色，見該檔）。生產路徑一律用 `SupabaseGrowthAPIClient`。
///
/// 非 `private`（LS-312 導覽入口接線起）：`RootView.swift`／`TapTargetGateHarness.swift` 的
/// preview／harness host 需要直接建構這個型別當 `growthAPIClient` 參數——同
/// `PreviewDiaryAPIClient` 本來就不是 `private` 的既有先例。
final class PreviewGrowthAPIClient: GrowthAPIClient, @unchecked Sendable {
    /// 表單送出的 `measuredOn` 是哪個時區的「本地午夜」——預設裝置時區（同
    /// `BirthdayFormat.wireString(from:timeZone:)` 預設值）；只有測試會注入固定時區。
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord] { [] }

    /// 同 `PreviewChildAPIClient.createChild`／`.updateChild` 的角色——不打真網路，原樣把輸入
    /// 組成一列回傳（`input.id` 為 nil 時視為新增，配一個新 `UUID`；非 nil 時視為編輯，沿用原
    /// `id`，`familyID`／`authorID`／`createdAt` 用不影響呈現的假值即可，呼叫端只在乎
    /// `heightCm`／`weightKg`／`headCm`／`note`／`measuredOn` 這幾項）。
    ///
    /// LS-335（LS-313 R3-m3）：`measuredOn` 比照真 RPC 的來回（`SupabaseGrowthAPIClient` 送
    /// `wireString`、後端回 `date`、`date(fromWireString:)` 解成 UTC 午夜）先正規化成 UTC 午夜
    /// ——原樣回傳本地午夜的話，UTC+ 時區（例 Asia/Taipei 的 8/20 00:00＝UTC 8/19 16:00）之後
    /// 一律用 UTC 抽年月日的顯示（`measuredOnHistoryLabel` 等）會退一天。
    func upsertGrowthRecord(childID: UUID, input: GrowthMeasurementInput) async throws -> GrowthRecord {
        let wireDay = BirthdayFormat.wireString(from: input.measuredOn, timeZone: timeZone)
        return GrowthRecord(
            id: input.id ?? UUID(), familyID: UUID(), childID: childID, authorID: GrowthStore.previewAuthorID,
            measuredOn: BirthdayFormat.date(fromWireString: wireDay) ?? input.measuredOn,
            heightCm: input.heightCm, weightKg: input.weightKg,
            headCm: input.headCm, note: input.note, createdAt: Date(), updatedAt: Date()
        )
    }

    func deleteGrowthRecord(id: UUID) async throws {}
}

extension GrowthStore {
    @MainActor
    static func preview(
        childID: UUID = UUID(), childName: String = "陳小安",
        childBirthday: Date = BirthdayFormat.date(fromWireString: "2025-04-20")!
    ) -> GrowthStore {
        GrowthStore(
            childID: childID, childName: childName, childBirthday: childBirthday,
            apiClient: PreviewGrowthAPIClient()
        )
    }

    /// Notes 統一示範資料集（`G1tRP9`）：陳小安，「今天」＝2026-08-20，出生 2025-04-20，
    /// 6 筆量測月齡 1/4/7/10/13/16（每 3 個月一筆，13mo 僅頭圍）——01／03／06 populated harness
    /// host／截圖對稿都用這組資料，逐字對齊 Notes 數值。全部 6 筆的 `authorID` 都是
    /// `GrowthStore.previewAuthorID`（LS-313）：harness／`#Preview` 把「目前登入者」也設成這個
    /// id（見 `ChildGrowthDetailView(previewGrowthStore:currentUserID:)`），才能同時展示 03
    /// 記錄列表「編輯」（僅作者）與「刪除」（作者或 owner）兩種動作列。
    @MainActor
    static func previewSeededWithDemoRecords(
        childID: UUID = UUID(), childName: String = "陳小安"
    ) -> GrowthStore {
        let store = GrowthStore.preview(childID: childID, childName: childName)
        let familyID = UUID()
        let authorID = GrowthStore.previewAuthorID
        func record(_ measuredOn: String, height: Double?, weight: Double?, head: Double?) -> GrowthRecord {
            let date = BirthdayFormat.date(fromWireString: measuredOn)!
            return GrowthRecord(
                id: UUID(), familyID: familyID, childID: childID, authorID: authorID, measuredOn: date,
                heightCm: height, weightKg: weight, headCm: head, note: nil, createdAt: date, updatedAt: date
            )
        }
        store.seedForPreview(records: [
            record("2025-05-20", height: 52.0, weight: 4.2, head: 37.5),
            record("2025-08-20", height: 62.5, weight: 6.8, head: 40.8),
            record("2025-11-20", height: 68.5, weight: 7.9, head: 42.6),
            record("2026-02-20", height: 73.0, weight: 8.7, head: 43.7),
            record("2026-05-20", height: nil, weight: nil, head: 44.4),
            record("2026-08-20", height: 78.5, weight: 9.6, head: 45.0)
        ])
        return store
    }
}
#endif
