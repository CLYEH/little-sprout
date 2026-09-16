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
                assetCount: group.assetLocalIdentifiers.count, maxSlots: maxThumbnailSlots,
                cellSize: thumbnailCellSize
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

    private var albumLabel: String {
        guard let albumID = group.albumID, let album = albums.first(where: { $0.id == albumID }) else {
            return "不放相簿"
        }
        return album.title
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

    private var skippedRow: some View {
        let dateLabel = ImportDateFormatting.groupHeaderLabel(for: group.anchorDate)
        let assetCount = group.assetLocalIdentifiers.count
        return HStack {
            Text("已略過・\(dateLabel)（\(assetCount) 張）")
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
            DatePicker("這群的日期", selection: $selection, displayedComponents: .date)
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
