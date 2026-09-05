import SwiftUI

/// 09／09b 儲存空間頁（`design/littlesprout.pen` `LS-152 / 09 儲存空間`／`09b 儲存空間 ·
/// 已滿`）——`get_family_quota` 用量／上限＋相紙卷（Print Roll）視覺；已滿（09b）與未滿（09）
/// 是同一個檔案依 `FamilyStore.quota.isFull` 切換的兩種狀態，不是兩支檔案（同稿面「狀態切換
/// 不搬動版面」規則：印品幾何／文案槽位固定，只換該狀態該有的文字與顏色）。
///
/// 額度查詢（`FamilyStore.refreshQuota()`）是 `.task` 觸發的 async RPC 呼叫，不在 view body
/// 內做任何同步／阻塞運算——這裡的 `usedGB`／`percent`／`filledChipCount` 都是拿到 `quota`
/// 之後的單純算術（O(1)），不涉及主執行緒阻塞（merge-review 效能重點）。
struct StorageUsageView: View {
    let familyStore: FamilyStore

    /// 稿面固定 12 格（`H5K5xm`/`ZG2Un` 兩板皆是），不是依螢幕寬度動態算格數。
    private static let totalChips = 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 8)
                cardSection
                    .padding(.top, AppSpacing.section)
                Text("照片與影片會佔用空間，日記文字不會。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                    .padding(.top, AppSpacing.block)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, AppSpacing.block)
        }
        .background(Color.lsBackground)
        .navigationTitle("儲存空間")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: familyStore.myFamily?.id) {
            await familyStore.refreshQuota()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("儲存空間")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(subtitle)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var subtitle: String {
        guard let quota = familyStore.quota else {
            return familyName.map { "「\($0)」所有人共用同一個儲存空間。" } ?? "所有人共用同一個儲存空間。"
        }
        guard quota.isFull else {
            return familyName.map { "「\($0)」所有人共用同一個儲存空間。" } ?? "所有人共用同一個儲存空間。"
        }
        return "先刪掉一些照片或影片，就能繼續上傳。"
    }

    private var familyName: String? { familyStore.myFamily?.name }

    @ViewBuilder
    private var cardSection: some View {
        switch (familyStore.quota, familyStore.quotaState) {
        case (let quota?, _):
            VStack(alignment: .leading, spacing: 0) {
                if quota.isFull {
                    warningRow
                        .padding(.bottom, AppSpacing.block)
                }
                usageCard(quota)
            }
        case (nil, .failure(let error)):
            quotaFailedView(message: error.userFacingMessage)
        default:
            ProgressView("正在讀取用量…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.block)
        }
    }

    private var warningRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill")
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsDanger)
            Text("儲存空間已滿，新的照片與影片沒辦法再上傳。")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsDanger)
        }
    }

    private func usageCard(_ quota: FamilyQuota) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(Self.gbString(quota.usedBytes)) 已使用")
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("／ \(Self.gbString(quota.quotaBytes))")
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            printRoll(quota)
            Text(percentNote(quota))
                .appFont(.note, weight: quota.isFull ? .semibold : .regular)
                .foregroundStyle(quota.isFull ? Color.lsDanger : Color.lsTextSecondary)
        }
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    private func printRoll(_ quota: FamilyQuota) -> some View {
        let filled = Self.filledChipCount(usedFraction: quota.usedFraction)
        return HStack(spacing: 3) {
            ForEach(0..<Self.totalChips, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index < filled ? Color.lsPhotoCorner : Color.lsPrintPaper)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.lsPaperEdge, lineWidth: 1)
                    )
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    private func percentNote(_ quota: FamilyQuota) -> String {
        guard !quota.isFull else { return "用了 100%，沒有剩餘空間了。" }
        let percent = Int((quota.usedFraction * 100).rounded())
        let remaining = max(0, quota.quotaBytes - quota.usedBytes)
        return "用了 \(percent)%，還有 \(Self.gbString(remaining)) 可以用。"
    }

    private func quotaFailedView(message: String) -> some View {
        VStack(spacing: AppSpacing.item) {
            Text(message)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
            // merge-review R1 m3：純文字 Button 天然高度只貼著文字本身（同 LS-17 QA1 的既有
            // 教訓，見 `SettingsRowView` 文件註解）——加 `.frame(minHeight: 44)`＋
            // `.contentShape(Rectangle())` 撐住長輩硬約束的點擊目標，不靠外層 padding。
            Button {
                Task { await familyStore.refreshQuota() }
            } label: {
                Text("重試")
                    .appFont(.body, weight: .semibold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.block)
    }

    /// 12 格中填滿的格數——四捨五入到最近整數格，同稿面 09（42%→5／12）／09b（100%→12／12）
    /// 兩組示意值的算法。
    static func filledChipCount(usedFraction: Double) -> Int {
        let raw = Int((usedFraction * Double(totalChips)).rounded())
        return min(totalChips, max(0, raw))
    }

    /// `storage_quota_bytes`／`storage_used_bytes` 都是以 1024³ 為底（預設 5368709120 ＝
    /// 5×1024³，見 `20260822120000_init_schema.sql`），稿面標成「GB」而非「GiB」——沿用稿面
    /// 用語，不在這裡另創「GiB」字樣造成與稿面不一致。整數 GB 不顯示小數點（稿面「／ 5 GB」
    /// 不是「／ 5.0 GB」）。
    static func gbString(_ bytes: Int64) -> String {
        "\(gbNumberString(bytes)) GB"
    }

    /// `gbString` 拿掉「 GB」單位字尾的版本——`compactUsageSummary` 組「2.1／5 GB」這種兩個
    /// 數字共用一個字尾單位的格式時需要單獨的數字字串，見該函式文件註解。
    private static func gbNumberString(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", gigabytes)
        }
        return String(format: "%.1f", gigabytes)
    }

    /// merge-review R1 m1：01 設定頁「儲存空間」列的用量摘要——稿面 `t5wI4` `Row · 儲存空間`
    /// （`AlJ6V`）覆寫 `n1hzsr.content = "2.1／5 GB"`：已用量的數字不重複「GB」單位，只有
    /// 上限那個數字帶單位。跟 09 頁本身「2.1 GB 已使用 ／ 5 GB」兩段各自帶單位的格式不同，
    /// 是這顆列自己的緊湊格式，不能直接借用 `gbString` 兩次拼接。
    static func compactUsageSummary(_ quota: FamilyQuota) -> String {
        "\(gbNumberString(quota.usedBytes))／\(gbString(quota.quotaBytes))"
    }
}

#if DEBUG
#Preview("09 · 未滿") {
    let store = FamilyStore.preview(withFamily: Family(
        id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
    ))
    store.seedQuotaForPreview(FamilyQuota(usedBytes: 2_254_857_830, quotaBytes: 5_368_709_120))
    return NavigationStack {
        StorageUsageView(familyStore: store)
    }
}

#Preview("09b · 已滿") {
    let store = FamilyStore.preview(withFamily: Family(
        id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
    ))
    store.seedQuotaForPreview(FamilyQuota(usedBytes: 5_368_709_120, quotaBytes: 5_368_709_120))
    return NavigationStack {
        StorageUsageView(familyStore: store)
    }
}
#endif
