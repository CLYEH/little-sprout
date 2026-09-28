import PhotosUI
import SwiftUI

/// `FoodRecordSheet` 的四個欄位（日期／照片／反應／一句話）——從主檔拆出（`type_body_length`，同
/// `FoodBookView+States.swift` 的既有拆檔先例）。不標 `private`：`private` 以檔案為界，跨檔 extension 存取不到。
extension FoodRecordSheet {
    // MARK: - 日期（稿 `j0pdR`）

    var dateField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            fieldLabel(FoodRecordCopy.dateLabel)
            Button {
                guard !store.saveState.isSubmitting else { return }
                showsDatePicker = true
            } label: {
                HStack(spacing: AppSpacing.label) {
                    Text(FoodRecordCopy.dateValue(store.firstTriedOn, twoLines: isAccessibilityLayout))
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "calendar")
                        .appIconFrame(.medium)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                .padding(.vertical, AppSpacing.group)
                .padding(.horizontal, AppSpacing.insetCard)
                .frame(minHeight: 48)
                .fieldBox()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(FoodRecordCopy.dateLabel)，\(FoodRecordCopy.dateValue(store.firstTriedOn, twoLines: false))"
            )
            .accessibilityIdentifier("foodRecord.date")
            HStack(alignment: .top, spacing: AppSpacing.label) {
                Image(systemName: "info.circle").appIconFrame(.small)
                Text(FoodRecordCopy.dateHelp)
                    .appFont(.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color.lsTextSecondary)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - 照片（稿 `IBDnS`／03b `uVqWC`）

    var photoField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            fieldLabel(store.photo == .none && !store.keepsUnresolvedExistingPhoto ? "照片（可不選）" : "照片")
            switch store.photo {
            case .none where store.keepsUnresolvedExistingPhoto:
                let failed = store.existingPhotoLoad == .failed
                selectedPhoto(label: failed ? FoodRecordCopy.existingPhotoUnavailable : "原照片") {
                    unresolvedThumbnail(failed: failed)
                }
            case .none:
                photoOptions
            case .family(let photo):
                selectedPhoto { remoteThumbnail(photoURLs[photo.displayPath]) }
            case .local(let local):
                selectedPhoto { localThumbnail(local.preview) }
            }
        }
    }

    private var photoOptions: some View {
        let family = outlineButton(title: "從家庭相簿挑", icon: "photo.on.rectangle", verticalPadding: .medium) {
            showsFamilyPicker = true
        }
        let phone = outlineButton(title: "從手機加入", icon: "iphone", verticalPadding: .medium) {
            showsPhonePicker = true
        }
        return Group {
            if isAccessibilityLayout {
                VStack(spacing: AppSpacing.group) { family; phone }
            } else {
                HStack(spacing: AppSpacing.group) { family; phone }
            }
        }
    }

    private func selectedPhoto(label: String = "已選的照片", @ViewBuilder thumbnail: () -> some View) -> some View {
        let thumb = thumbnail()
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier("foodRecord.photoThumb")
        let actions = VStack(spacing: AppSpacing.group) {
            outlineButton(title: "換一張", icon: "arrow.clockwise", verticalPadding: .tap) {
                showsPhoneSourceChoice = true
            }
            outlineButton(title: "不用照片", icon: "xmark", verticalPadding: .tap) { store.removePhoto() }
        }
        return Group {
            if isAccessibilityLayout {
                VStack(alignment: .leading, spacing: AppSpacing.item) { thumb; actions }
            } else {
                HStack(spacing: AppSpacing.item) { thumb; actions }
            }
        }
    }

    private func remoteThumbnail(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Color.lsSurface2
            }
        }
    }

    /// 03b 原照片還沒讀到／讀不到（R1 i4）：同一格縮圖位，讀取中留空白底，失敗時寫明「原照片讀取失敗」
    /// ——旁邊照樣有「換一張／不用照片」，畫面與送出的 `media_id` 一致。
    private func unresolvedThumbnail(failed: Bool) -> some View {
        Color.lsSurface2.overlay {
            if failed {
                Text(FoodRecordCopy.existingPhotoUnavailable)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(AppSpacing.tight)
            }
        }
    }

    @ViewBuilder
    private func localThumbnail(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.lsSurface2
        }
    }

    // MARK: - 反應（稿 `WVifd`）

    var reactionField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            fieldLabel(FoodRecordCopy.reactionLabel(childName: childName))
            let options = ForEach(FoodReaction.allCases) { reaction in reactionOption(reaction) }
            if isAccessibilityLayout {
                VStack(spacing: AppSpacing.label) { options }
            } else {
                HStack(spacing: AppSpacing.label) { options }
            }
        }
    }

    /// 選中＝`$accent-soft` 底＋`$text-primary` 2pt 框＋字 700（03b `IrRNX`）；未選＝`$surface`＋
    /// `$control-line` 1.5pt＋字 600。再點一次取消（Notes `m18MTy`）。
    private func reactionOption(_ reaction: FoodReaction) -> some View {
        let isSelected = store.reaction == reaction
        let shape = RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
        return Button {
            guard !store.saveState.isSubmitting else { return }
            store.toggleReaction(reaction)
        } label: {
            HStack(spacing: AppSpacing.tight) {
                FoodReactionIcon(reaction: reaction).appIconFrame(.medium)
                Text(reaction.label).appFont(.body, weight: isSelected ? .bold : .semibold)
            }
            .foregroundStyle(Color.lsTextPrimary)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, AppSpacing.label)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isSelected ? Color.lsAccentSoft : Color.lsSurface, in: shape)
            .overlay(shape.strokeBorder(
                isSelected ? Color.lsTextPrimary : Color.lsControlLine, lineWidth: isSelected ? 2 : 1.5
            ))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reaction.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("foodRecord.reaction.\(reaction.rawValue)")
    }

    // MARK: - 一句話（稿 `r6MyA7`）

    var noteField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            fieldLabel("一句話（可不填）")
            // 提示句自己疊一層 `Text`（不用 `prompt:`）：`axis: .vertical` 的 prompt 只排一行，AX3 會截成
            // 「例如：一口接一…」，稿 `Bmm00` 是完整換行。
            ZStack(alignment: .topLeading) {
                if store.note.isEmpty {
                    Text(FoodRecordCopy.notePlaceholder)
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextSecondary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $store.note, axis: .vertical)
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextPrimary)
            }
            .padding(AppSpacing.insetCard)
            .frame(minHeight: isAccessibilityLayout ? nil : 84, alignment: .topLeading)
            .fieldBox()
            .disabled(store.saveState.isSubmitting)
            .accessibilityLabel("一句話")
            .accessibilityIdentifier("foodRecord.note")
        }
    }

    // MARK: - 共用

    func fieldLabel(_ text: String) -> some View {
        Text(text)
            .appFont(.body, weight: .bold)
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum OutlinePadding {
        case medium
        case tap

        var value: CGFloat {
            switch self {
            case .medium: AppSpacing.controlPaddingMedium
            case .tap: AppSpacing.controlPaddingTap
            }
        }
    }

    /// cmp/Button Secondary（`XggYA`）：無填色、`$control-line` 1.5pt、icon＋字 600 置中。
    func outlineButton(
        title: String, icon: String, verticalPadding: OutlinePadding, action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !store.saveState.isSubmitting else { return }
            action()
        } label: {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: icon).appIconFrame(.medium)
                Text(title).appFont(.body, weight: .semibold)
            }
            .foregroundStyle(Color.lsTextPrimary)
            .padding(.vertical, verticalPadding.value)
            .padding(.horizontal, AppSpacing.group)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// 欄位框（稿 `e0oF0`／`yCiqQ`：`$surface`＋`$control-line` 1.5pt＋`$radius-md`）。
    func fieldBox() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
        return background(Color.lsSurface, in: shape)
            .overlay(shape.strokeBorder(Color.lsControlLine, lineWidth: 1.5))
    }
}
