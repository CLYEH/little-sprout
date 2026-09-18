import SwiftUI

/// 匯入整理頁一張群卡（`design/littlesprout.pen` Import 01/02/03「群卡兩群節奏」，LS-251 R3
/// MN-16 重建版式）——內容群（Top Row＋Thumb Row，內部 gap `$sp-label` 8）／控制群（Babies
/// Row＋Info Row，內部 gap 8），群間 `$sp-block`（24）。
///
/// AX3（`dynamicTypeSize.isAccessibilitySize`）：Info Row（相簿列＋略過鈕）改直式堆疊
/// （R3 MN-16：Album Chip 276＋Skip 202＝478 超出 305 容器在 40pt 下互相重疊）。
///
/// 「已略過」態＝收合成一行（R2 起的記憶點：「已略過」收合列＋主鈕 N 即時扣除，見
/// `ImportOrganizeView.pendingAssetCount`）。
struct ImportGroupCardView: View {
    @Binding var group: ImportPlan.Group
    let children: [Child]
    let albums: [AlbumSummary]
    let maxThumbnailSlots: Int
    let thumbnailCellSize: CGFloat
    /// LS-303 R2（merge-review R1 M1）：`nil` 時（harness／preview 無真的 `PHAsset`）縮圖格
    /// 全部退回系統圖示佔位，見 `ImportThumbnailCell`。
    let thumbnailProvider: ImportThumbnailProvider?
    /// LS-303 R5（merge-review R4 i2）：入口來源（`ImportEntrySource.albumDetail`）已知的
    /// 相簿 id／名稱，`albumLabel` 在 `albums` 清單查不到 `group.albumID` 時的 fallback，
    /// 見該屬性文件註解。
    let fallbackAlbumID: UUID?
    let fallbackAlbumName: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// LS-303：日期不明群的「可改日期」——`DatePicker(displayedComponents: .date)` 在
    /// `.compact` 樣式下熱區量到 149.7×34.3pt（<44pt），同 `DiaryDatePickerSheet` 既有踩雷
    /// 記錄的教訓：改成 Button 觸發 `.wheel` 樣式 sheet，見 `datePickerSheet`。
    @State private var showsDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.isSkipped {
                skippedRow
            } else {
                contentGroup
                    .padding(.bottom, AppSpacing.block)
                controlGroup
            }
        }
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge).strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    // MARK: - 內容群（Top Row／Thumb Row）

    private var contentGroup: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            topRow
            ImportThumbnailGridView(
                assetIDs: group.assetLocalIdentifiers, maxSlots: maxThumbnailSlots,
                provider: thumbnailProvider, cellSize: thumbnailCellSize
            )
        }
    }

    private var topRow: some View {
        HStack(alignment: .firstTextBaseline) {
            groupTitle
            Spacer(minLength: AppSpacing.label)
            Text("共 \(group.assetLocalIdentifiers.count) 張")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    /// C4a①「9月10日」／C4a②「今天（9/15）」＋日期不明群可改日期
    /// （`DatePicker`，票文範圍 2）。
    private var groupTitle: some View {
        Group {
            if group.isDateUnknown {
                HStack(spacing: AppSpacing.label) {
                    Text("日期不明").appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                    Button {
                        showsDatePicker = true
                    } label: {
                        HStack(spacing: AppSpacing.tight) {
                            Text(ImportDateFormatting.unknownDateGroupLabel(anchorDate: group.anchorDate))
                                .appFont(.note, weight: .semibold)
                            Image(systemName: "chevron.right").appIconFrame(.small)
                        }
                        .foregroundStyle(Color.lsTextSecondary)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(
                        "這群的日期，\(ImportDateFormatting.unknownDateGroupLabel(anchorDate: group.anchorDate))"
                    )
                }
                .sheet(isPresented: $showsDatePicker) {
                    ImportGroupDatePickerSheet(selection: $group.anchorDate)
                }
            } else {
                Text(ImportDateFormatting.groupHeaderLabel(for: group.anchorDate))
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
            }
        }
    }

    // MARK: - 控制群（Babies Row／Info Row）

    private var controlGroup: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            if children.isEmpty {
                Text("這個家庭還沒有寶貝資料")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            } else {
                BabyChipRow(
                    children: children, selectedChildIDs: Set(group.babyIDs),
                    onToggle: { toggleBaby($0) }
                )
                if group.babyIDs.isEmpty {
                    // R2 MN-5：不 disable 主鈕，只用回話列提醒——這群還沒有指定寶貝。
                    HStack(spacing: AppSpacing.label) {
                        Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                            .foregroundStyle(Color.lsTextPrimary)
                        Text("這群還沒有指定寶貝").appFont(.note).foregroundStyle(Color.lsTextPrimary)
                    }
                }
            }
            infoRow
        }
    }

    private var infoRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AppSpacing.label) { albumChip; skipButton }
            } else {
                HStack { albumChip; Spacer(minLength: AppSpacing.label); skipButton }
            }
        }
    }

    private var albumChip: some View {
        Menu {
            Button("不放相簿") { group.albumID = nil }
            ForEach(albums) { album in
                Button(album.title) { group.albumID = album.id }
            }
        } label: {
            HStack(spacing: AppSpacing.tight) {
                Text(albumLabel).appFont(.note, weight: .semibold).foregroundStyle(Color.lsTextPrimary)
                Image(systemName: "chevron.down").appIconFrame(.small).foregroundStyle(Color.lsTextSecondary)
            }
            .padding(.horizontal, AppSpacing.label)
            .frame(minHeight: 48)
            .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .accessibilityLabel("這群放進的相簿，目前\(albumLabel)")
    }

    /// merge-review R2 i5／R3 i6：`group.albumID` 非 nil 但 `albums` 清單裡還查不到那本
    /// （例如 `AlbumsStore.albums` 剛好在重新整理）時，原本一律顯示「不放相簿」——文字與
    /// 實際資料相反（`ImportPlan` 其實帶著這個 `albumID`，主鈕按下去真的會放進那本相簿），
    /// 使用者會被字面誤導成「沒選、可以放心按」。「不放相簿」只在 `albumID == nil`（使用者
    /// 真的選了這個選項，或 C3a 一般案的預設值）時顯示。
    ///
    /// merge-review R4 i2：`albumID` 有值但查無資料時，R3 版本顯示稿外新造文案
    /// 「相簿載入中…」——改用入口來源已經知道的相簿名稱（`fallbackAlbumID`／
    /// `fallbackAlbumName`，見兩者文件註解）當 fallback，不需要新造任何文案。這覆蓋唯一會
    /// 發生的情況：入口來源預設的那本相簿還沒出現在 `AlbumsStore.albums` 清單裡（使用者從
    /// `albumChip` 選單另選的相簿一定已經在 `albums` 裡，前面的 `first(where:)` 就會命中）。
    private var albumLabel: String {
        guard let albumID = group.albumID else { return "不放相簿" }
        if let album = albums.first(where: { $0.id == albumID }) { return album.title }
        if albumID == fallbackAlbumID, let fallbackAlbumName { return fallbackAlbumName }
        return "不放相簿"
    }

    private var skipButton: some View {
        Button {
            group.isSkipped = true
        } label: {
            Text("略過這群").appFont(.note, weight: .semibold).foregroundStyle(Color.lsTextSecondary)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
        }
    }

    // MARK: - 已略過收合列

    /// LS-303 R2（merge-review R1 i4）：日期不明群略過後仍要用 C4a②「今天（9/16）」格式，
    /// 不能落回 C4a① 的「9月16日」——「今天」正是標示這是系統推測值的語意，略過與否不改變
    /// 這個群本身的日期不明狀態。
    private var dateLabel: String {
        group.isDateUnknown
            ? ImportDateFormatting.unknownDateGroupLabel(anchorDate: group.anchorDate)
            : ImportDateFormatting.groupHeaderLabel(for: group.anchorDate)
    }

    private var skippedRow: some View {
        let assetCount = group.assetLocalIdentifiers.count
        return HStack {
            // LS-303 R2（merge-review R1 M3）：稿面 `m7ZCDg` 逐字「9月8日・8 張已略過」。
            Text("\(dateLabel)・\(assetCount) 張已略過")
                .appFont(.note).foregroundStyle(Color.lsTextSecondary)
            Spacer(minLength: AppSpacing.label)
            Button {
                group.isSkipped = false
            } label: {
                Text("取消略過").appFont(.note, weight: .semibold)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
            }
        }
    }

    private func toggleBaby(_ id: UUID) {
        if let index = group.babyIDs.firstIndex(of: id) {
            group.babyIDs.remove(at: index)
        } else {
            group.babyIDs.append(id)
        }
    }
}

/// 日期不明群「可改日期」——同 `DiaryDatePickerSheet`（`DiaryEditorView.swift`）既有寫法：
/// `.wheel` 樣式＋自畫「完成」鈕（`Button{}label:{}` 把 padding/frame 做在 label 內部，
/// `.contentShape(Rectangle())` 鎖熱區，同檔文件註解記錄的既有踩雷教訓）。
struct ImportGroupDatePickerSheet: View {
    @Binding var selection: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Text("選擇日期").appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            // merge-review R1 M1：稿面／票文都沒有「未來日期」情境，但 wheel 可以無限往後滾——
            // 未夾上界會讓這一群的 `taken_at` 撞後端 `media_taken_at_range_check` 整批被拒
            // （同 `CreateChildView.BirthdayPickerSheet` 既有寫法，`in: ...Date()`）。
            DatePicker("這群的日期", selection: $selection, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
            Button {
                dismiss()
            } label: {
                Text("完成")
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingCTA)
                    .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                            .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
                    )
            }
        }
        .padding(AppSpacing.screenPad)
        .presentationDetents([.medium])
    }
}
