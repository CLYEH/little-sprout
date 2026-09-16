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
        /// `nil` = 「不放相簿」——C3a 使用者裁決：不論入口（相簿詳情／時間軸）一律預設不放
        /// 相簿，不依入口分支（見 LS-249 comment `5e180074`）。
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
}

/// 2/2（上傳→摘要，blockedBy 本票）的入口介面——本票只接 no-op stub，真正的實作在 LS-249
/// 2/2 補上。`ImportOrganizeView` 的主鈕按下時呼叫 `startImport(plan:)`，不關心它怎麼做。
protocol ImportUploadCoordinator {
    @MainActor
    func startImport(plan: ImportPlan)
}

/// 本票唯一的 `ImportUploadCoordinator` 實作——不做任何事，只用來讓「開始匯入」鈕有東西可以
/// 呼叫、確認 `ImportPlan` 在主鈕按下當下的形狀是對的（見 `ImportOrganizeViewModelTests`）。
/// 2/2 落地後這支會被真正的實作取代，呼叫端（`ImportOrganizeView` 的建構參數）不需要跟著改
/// ——這正是拉這層 protocol 的理由。
struct NoOpImportUploadCoordinator: ImportUploadCoordinator {
    var onStart: (@MainActor (ImportPlan) -> Void)?

    @MainActor
    func startImport(plan: ImportPlan) {
        onStart?(plan)
    }
}
