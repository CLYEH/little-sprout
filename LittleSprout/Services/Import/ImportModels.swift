import Foundation

/// 相機膠卷批次匯入「選取→整理」純資料模型（LS-303，`design/littlesprout.pen`
/// `Import / 01–06b`，LS-251 核可稿 head `5cf02ae`；使用者裁決 C1a–C4a 見 LS-249 comment
/// `5e180074`）。整理頁把 PHPicker 選出的相片依拍攝日期分成若干 `ImportPlan.Group`，本票
/// 只做到「整理完成、按下主鈕」——實際上傳／進度／摘要交給 LS-249 2/2（blockedBy 本票，見
/// `ImportUploadCoordinator`）。
struct ImportPlan: Codable, Equatable {
    struct Group: Codable, Equatable, Identifiable {
        /// 已知日期群＝`yyyy-MM-dd`（裝置本地時區起始日）；日期不明群固定
        /// `ImportDateGrouping.unknownDateGroupID`。
        var id: String
        /// 群卡標題用的錨點日期——已知日期群＝該日期本身（C4a①「9月10日」）；日期不明群＝
        /// 使用者可改的推測值，預設今天（C4a②「今天（9/15）」）。
        var anchorDate: Date
        var isDateUnknown: Bool
        /// `PHAsset.localIdentifier` 陣列，維持選取／分組時的原始順序。
        var assetLocalIdentifiers: [String]
        var babyIDs: [UUID]
        /// `nil` = 「不放相簿」。LS-303 R2（merge-review R1 M2，orchestrator 裁決
        /// `c997f234`，覆寫 C3a 的一般案）：從相簿詳情進入時預設為該相簿（`ImportEntrySource
        /// .albumDetail(albumID:)`，可改），其餘入口才維持 C3a「預設不放相簿」。
        var albumID: UUID?
        var isSkipped: Bool

        init(
            id: String, anchorDate: Date, isDateUnknown: Bool, assetLocalIdentifiers: [String],
            babyIDs: [UUID] = [], albumID: UUID? = nil, isSkipped: Bool = false
        ) {
            self.id = id
            self.anchorDate = anchorDate
            self.isDateUnknown = isDateUnknown
            self.assetLocalIdentifiers = assetLocalIdentifiers
            self.babyIDs = babyIDs
            self.albumID = albumID
            self.isSkipped = isSkipped
        }
    }

    var groups: [Group]

    /// 主鈕「開始匯入 N 張」的 N——略過的群不計入，隨 `isSkipped` 即時變動（LS-303 範圍 3
    /// 驗收：「N 隨略過即時對應」）。
    var pendingAssetCount: Int {
        groups.filter { !$0.isSkipped }.reduce(0) { $0 + $1.assetLocalIdentifiers.count }
    }

    /// 頂部摘要「共 N 張・M 個日期群」的 N（略過與否都算，反映整批選取結果本身）。
    var totalAssetCount: Int {
        groups.reduce(0) { $0 + $1.assetLocalIdentifiers.count }
    }

    /// 頂部摘要的 M——只算日期群數（沿設計稿 03 板「共 200 張・7 個日期群」語意，日期不明
    /// 群本身也算一群）。
    var groupCount: Int { groups.count }

    /// LS-303 R3（merge-review R2 M2，orchestrator 裁決）：`LegacyAlbumUploadImportCoordinator`
    /// 過渡版只支援「每群都指定相簿」——有未略過、且非空、卻沒有 `albumID` 的群，代表主鈕按下
    /// 去會有照片沒有地方可放。`ImportOrganizeView.ctaBar` 用這個純函式決定是否停用主鈕＋
    /// 顯示提示，見 `ImportUploadCoordinator.requiresAlbumSelection`。
    var hasUnskippedGroupsWithoutAlbum: Bool {
        groups.contains { !$0.isSkipped && !$0.assetLocalIdentifiers.isEmpty && $0.albumID == nil }
    }
}

/// 匯入流程的觸發入口（LS-303 R2，merge-review R1 M2，orchestrator 裁決 `c997f234`）——
/// 決定整理頁每群 `albumID` 的預設值。`.timeline` 本票沒有任何呼叫點（時間軸批次匯入入口
/// 移出本票，另開 lane:design 決策票，有稿再接），保留這個 case 是讓型別本身描述完整的
/// 入口空間，供該票落地時直接重用，不需要再改 `ImportPlan`／`ImportOrganizeView` 的介面。
enum ImportEntrySource: Equatable {
    /// LS-303 R5（merge-review R4 i2）：`albumName` 是這本相簿當下的標題——整理頁相簿列
    /// （`ImportGroupCardView.albumLabel`）在 `AlbumsStore.albums` 清單還沒載入完成、查不到
    /// 這個 `albumID` 時拿這個字串當 fallback 顯示，不用稿外新造「相簿載入中…」文案。
    case albumDetail(albumID: UUID, albumName: String)
    case timeline

    /// 整理頁各群 `albumID` 的初始值。
    var defaultAlbumID: UUID? {
        switch self {
        case .albumDetail(let albumID, _): albumID
        case .timeline: nil
        }
    }

    /// 見 `albumDetail` case 文件註解；`.timeline` 沒有已知相簿名稱。
    var defaultAlbumName: String? {
        switch self {
        case .albumDetail(_, let albumName): albumName
        case .timeline: nil
        }
    }

    /// 套用入口來源的相簿預設值到每一群——純函式，`ImportOrganizeView.init` 呼叫，抽出來
    /// 是讓這條規則能離開 SwiftUI View 生命週期單獨測試（見
    /// `ImportEntrySourceTests.test_applyDefaultAlbum_*`）。
    func applyDefaultAlbum(to groups: [ImportPlan.Group]) -> [ImportPlan.Group] {
        guard let albumID = defaultAlbumID else { return groups }
        return groups.map { group in
            var group = group
            group.albumID = albumID
            return group
        }
    }
}

/// 2/2（上傳→摘要，blockedBy 本票）的入口介面——`ImportOrganizeView` 的主鈕按下時呼叫
/// `startImport(plan:)`，不關心它怎麼做。LS-303 R3（merge-review R2 M2）在 2/2 落地前接了一個
/// 過渡實作（`LegacyAlbumUploadImportCoordinator`），本票不再只有 no-op stub。
protocol ImportUploadCoordinator {
    @MainActor
    func startImport(plan: ImportPlan)

    /// LS-303 R3（merge-review R2 M2）：這個實作是否要求整理頁每一個未略過群都指定相簿——
    /// `ImportOrganizeView.ctaBar` 讀這個旗標決定要不要在使用者選「不放相簿」時停用主鈕＋
    /// 提示「本版需先選相簿」。預設 `false`（`NoOpImportUploadCoordinator`／未來 LS-304 的
    /// 完整版都不需要這個限制）；只有 `LegacyAlbumUploadImportCoordinator` 覆寫成 `true`。
    /// `@MainActor`：同 `startImport(plan:)`——`LegacyAlbumUploadImportCoordinator` 整支是
    /// `@MainActor final class`，protocol 需求不標 `@MainActor` 的話，該型別的 conformance
    /// 在 Swift 6 嚴格並行檢查下會被視為跨 actor 邊界（編譯期錯誤，非警告）。
    @MainActor
    var requiresAlbumSelection: Bool { get }
}

extension ImportUploadCoordinator {
    @MainActor
    var requiresAlbumSelection: Bool { false }
}

/// 本票唯一在 2/2 落地前的預設實作（harness／preview／`.timeline` 入口尚未接線時使用）——不做
/// 任何事，只用來讓「開始匯入」鈕有東西可以呼叫、確認 `ImportPlan` 在主鈕按下當下的形狀是對的
/// （見 `ImportOrganizeViewModelTests`）。2/2 落地後 `LegacyAlbumUploadImportCoordinator` 也會
/// 被真正的實作取代，呼叫端（`ImportOrganizeView` 的建構參數）不需要跟著改——這正是拉這層
/// protocol 的理由。
struct NoOpImportUploadCoordinator: ImportUploadCoordinator {
    var onStart: (@MainActor (ImportPlan) -> Void)?

    @MainActor
    func startImport(plan: ImportPlan) {
        onStart?(plan)
    }
}
