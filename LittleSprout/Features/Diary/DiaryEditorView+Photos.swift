import PhotosUI
import SwiftUI

/// 照片佇列（`design/littlesprout.pen` `LS-21 / 12` Photos／`12d`／`12e`／`12f`／`12g`）：
/// 「新增照片」永遠第一格、單擊縮圖＝勾選（多選）、長按拖曳排序（放開後才重新排序，見
/// `DiaryPhotoReorderMath` 文件註解）、20 張上限與 60 秒影片提示各自是常駐回話列（不是彈窗）。
extension DiaryEditorView {
    var photosSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            photosHeader
            photoStrip
            if store.isAtCapacity { capReplyRow }
            ForEach(store.overLongVideoDrafts) { draft in
                videoLengthReplyRow(draft)
            }
            Text("按住照片可拖動調整順序")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
            if !store.selectedPhotoIDs.isEmpty {
                removeSelectedButton
            }
        }
        .photosPicker(
            isPresented: $showsPhotosPicker, selection: $pickerSelection,
            maxSelectionCount: max(1, store.remainingSlots), matching: .any(of: [.images, .videos])
        )
    }

    private var photosHeader: some View {
        HStack {
            Text("附加照片").appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            Spacer(minLength: 0)
            Text("\(store.photos.count)／\(DiaryComposerStore.photoCapacity) 張")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.label) {
                addPhotoCell
                ForEach(Array(store.photos.enumerated()), id: \.element.id) { index, photo in
                    photoCell(photo, index: index)
                }
            }
        }
    }

    private var addPhotoCell: some View {
        Button {
            guard store.remainingSlots > 0 else { return }
            showsPhotosPicker = true
        } label: {
            VStack(spacing: AppSpacing.label) {
                Image(systemName: "plus")
                    .appIconFrame(.large)
                    .foregroundStyle(Color.lsPrintInkSecondary)
                Text("新增照片")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsPrintInkSecondary)
                    .multilineTextAlignment(.center)
            }
            // R5（`design/littlesprout.pen` Handoff Notes `PoZUw`）：AX3 下「新增照片」換成兩行後
            // 固定 96 高度會裁字——本輪唯一一個「容器不寫死高度」的例外，其餘沿用既有硬寫 96。
            .frame(width: 96, height: dynamicTypeSize.isAccessibilitySize ? nil : 96)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? AppSpacing.label : 0)
            .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.publishState.isInFlight)
    }

    private func photoCell(_ photo: DiaryPhotoDraft, index: Int) -> some View {
        let isSelected = store.isSelected(photo.id)
        let isDragging = draggingPhotoID == photo.id
        return VStack(alignment: .leading, spacing: AppSpacing.tight) {
            thumbnail(photo, isSelected: isSelected)
                .offset(x: isDragging ? dragTranslationX : 0)
                .scaleEffect(isDragging ? 1.15 : 1)
                .rotationEffect(.degrees(isDragging ? -6 : 0))
                .shadow(
                    color: isDragging ? Color.lsPrintInk.opacity(0.3) : .clear, radius: 8, x: 2, y: 8
                )
                .zIndex(isDragging ? 1 : 0)
            if dynamicTypeSize.isAccessibilitySize, let duration = photo.videoDuration {
                Text("影片 \(DiaryDurationFormat.string(from: duration))")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
        .onTapGesture { store.toggleSelection(photo.id) }
        .simultaneousGesture(reorderGesture(for: photo))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: photo, index: index, isSelected: isSelected))
        .accessibilityAction(named: "往前移") { store.moveEarlier(photo.id) }
        .accessibilityAction(named: "往後移") { store.moveLater(photo.id) }
    }

    private func thumbnail(_ photo: DiaryPhotoDraft, isSelected: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let previewImage = photo.previewImage {
                    Image(uiImage: previewImage).resizable().scaledToFill()
                } else {
                    Color.lsSurface2
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(isSelected ? Color.lsTextPrimary : Color.clear, lineWidth: 2)
            )
            if photo.isVideo, let duration = photo.videoDuration {
                videoBadge(duration: duration)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if isSelected {
                selectedBadge
            }
        }
        .frame(width: 96, height: 96)
    }

    private func videoBadge(duration: TimeInterval) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
            Text("影片 \(DiaryDurationFormat.string(from: duration))")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.lsOnPhoto)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.lsPrintInk.opacity(0.75), in: Capsule())
    }

    private var selectedBadge: some View {
        Circle()
            .fill(Color.lsTextPrimary)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.lsSurface)
            )
            .offset(x: 6, y: -6)
    }

    private func accessibilityLabel(for photo: DiaryPhotoDraft, index: Int, isSelected: Bool) -> String {
        var parts = [photo.isVideo ? "影片" : "照片", "第 \(index + 1) 張，共 \(store.photos.count) 張"]
        if let duration = photo.videoDuration {
            parts.append("長度 \(DiaryDurationFormat.string(from: duration))")
        }
        if isSelected { parts.append("已選取") }
        return parts.joined(separator: "，")
    }

    private func reorderGesture(for photo: DiaryPhotoDraft) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 4))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    draggingPhotoID = photo.id
                    dragTranslationX = drag?.translation.width ?? 0
                default:
                    break
                }
            }
            .onEnded { value in
                defer {
                    draggingPhotoID = nil
                    dragTranslationX = 0
                }
                guard case .second(true, let drag?) = value,
                      let sourceIndex = store.photos.firstIndex(where: { $0.id == photo.id }) else { return }
                let targetIndex = DiaryPhotoReorderMath.targetIndex(
                    sourceIndex: sourceIndex, translationWidth: drag.translation.width, count: store.photos.count
                )
                store.move(id: photo.id, toIndex: targetIndex)
            }
    }

    private var capReplyRow: some View {
        replyRow(text: "最多 20 張，想放更多可以建相簿")
    }

    private func videoLengthReplyRow(_ draft: DiaryPhotoDraft) -> some View {
        replyRow(text: "這支影片 \(DiaryDurationFormat.string(from: draft.videoDuration ?? 0))，發佈時會保留前 60 秒")
    }

    private func replyRow(text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextPrimary)
            Text(text)
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
        }
    }

    private var removeSelectedButton: some View {
        Button {
            store.removeSelected()
        } label: {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "trash")
                Text("移除所選 \(store.selectedPhotoIDs.count) 張")
            }
            .appFont(.body, weight: .semibold)
            .foregroundStyle(Color.lsDanger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
        }
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(Color.lsDanger, lineWidth: 1.5)
        )
        .disabled(store.publishState.isInFlight)
    }

    @MainActor
    func loadPicked(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard !store.isAtCapacity else { break }
            guard let loaded = await PickedItemLoader.load(item) else { continue }
            switch loaded {
            case .photo(let data, let fileExtension, let pixelSize, let previewImage):
                store.addPhoto(
                    data: data, fileExtension: fileExtension, pixelSize: pixelSize, previewImage: previewImage
                )
            case .video(let fileURL, let fileExtension, let duration, let pixelSize, let previewImage):
                store.addVideo(
                    fileURL: fileURL, fileExtension: fileExtension, duration: duration,
                    pixelSize: pixelSize, previewImage: previewImage
                )
            }
        }
    }
}
