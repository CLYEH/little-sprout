import SwiftUI

/// 03d 從家庭相簿挑一張（LS-380，`design/littlesprout.pen` `OoYLu`〔iPhone〕／`CkOy9`〔AX3〕）。
///
/// 畫面級屬性（Notes `jyt14` 03d 列 `uniIm`）：隱藏 Tab Bar ✗（sheet）；標題自訂（置中 Head Title＋Head
/// Sub）；釘底動作帶無——格子區在中間捲動、「用這張／取消」在格子區之後（稿面 Picker Sheet 高 790、格子區
/// `fill_container`）；失敗文案鍵 42501（讀取失敗顯示 `AppError.userFacingMessage`＋重新載入）；深色 token
/// 自動；AX3 格子改 2 欄、縮圖高 130（`CkOy9`）；iPad 同一 sheet；資料落點：選中＝純 UI 狀態，「用這張」才
/// 回填 `media_id`。
///
/// 分段與排序見 `FamilyPhotoSections`（Notes `m18MTy`）；縮圖一律載 `thumb_path`（`FamilyPhoto.displayPath`，
/// 不載原圖），簽名 URL 一次批次取（不逐張打 Storage）。
struct FoodFamilyPhotoPickerSheet: View {
    let childID: UUID
    let recordDate: Date
    let apiClient: FoodAPIClient
    let initialSelectionID: UUID?
    let onUse: (FamilyPhoto, URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var photos: [FamilyPhoto]?
    @State private var loadError: AppError?
    @State private var urls: [String: URL] = [:]
    @State private var selectedID: UUID?

    init(
        childID: UUID, recordDate: Date, apiClient: FoodAPIClient, initialSelectionID: UUID?,
        onUse: @escaping (FamilyPhoto, URL?) -> Void
    ) {
        self.childID = childID
        self.recordDate = recordDate
        self.apiClient = apiClient
        self.initialSelectionID = initialSelectionID
        self.onUse = onUse
        _selectedID = State(initialValue: initialSelectionID)
    }

    private var isAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            header
            content
                .frame(maxHeight: .infinity, alignment: .top)
            actions
        }
        .padding(.top, AppSpacing.block)
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.bottom, AppSpacing.item)
        .background(Color.lsSurface)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: AppSpacing.group) {
            Capsule()
                .fill(Color.lsBorder)
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)
            Text("從家庭相簿挑一張")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("點一張照片，再按「用這張」。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let photos {
            if photos.isEmpty {
                Text("家庭相簿裡還沒有照片，可以改用「從手機加入」。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid(FamilyPhotoSections.make(photos: photos, recordDate: recordDate))
            }
        } else if let loadError {
            VStack(spacing: AppSpacing.item) {
                Text(loadError.userFacingMessage).appFont(.body).multilineTextAlignment(.center)
                Button {
                    Task { await load() }
                } label: {
                    Text("重新載入").appFont(.body, weight: .semibold).frame(minHeight: 48)
                }
            }
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func grid(_ sections: [FamilyPhotoSection]) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: AppSpacing.label), count: isAccessibilityLayout ? 2 : 3
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.item) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: AppSpacing.label) {
                        Text(section.title)
                            .appFont(.body, weight: .bold)
                            .foregroundStyle(Color.lsTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: columns, spacing: AppSpacing.label) {
                            ForEach(section.photos) { photo in thumb(photo) }
                        }
                    }
                }
            }
            // 選中框的勾勾徽章往上凸 4pt（稿 `HtN04` y −4），留白不讓 ScrollView 裁到。
            .padding(.top, 4)
        }
    }

    /// 選中＝`$text-primary` 3pt 內框＋右上勾勾徽章（稿 `w8wdp`／`HtN04`）。
    private func thumb(_ photo: FamilyPhoto) -> some View {
        let isSelected = selectedID == photo.id
        let shape = RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
        return Button {
            selectedID = isSelected ? nil : photo.id
        } label: {
            // 格子尺寸由底色決定、照片疊上去再裁——直接對 `scaledToFill` 的圖下 `frame(maxWidth:)`，非正方形的
            // 照片會把自己的理想寬度撐出欄外、蓋到隔壁格（E2E 用真照片實測抓到）。
            Color.lsSurface2
                .frame(maxWidth: .infinity)
                .frame(height: isAccessibilityLayout ? 130 : 104)
                .overlay {
                    AsyncImage(url: urls[photo.displayPath]) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                }
                .clipShape(shape)
            .overlay { if isSelected { shape.strokeBorder(Color.lsTextPrimary, lineWidth: 3) } }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.bold)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Color.lsSurface)
                        .frame(width: 24, height: 24)
                        .background(Color.lsTextPrimary, in: Circle())
                        .offset(x: -3, y: -4)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(for: photo))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("foodPhoto.\(photo.id.uuidString)")
    }

    private static func accessibilityLabel(for photo: FamilyPhoto) -> String {
        "照片，\(photo.sortDate.formatted(.dateTime.year().month().day()))"
    }

    private var actions: some View {
        VStack(spacing: AppSpacing.group) {
            PrimaryButton(title: "用這張") { useSelected() }
                .accessibilityIdentifier("foodPhoto.use")
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 品牌規則不 disable 主鈕：還沒選就按「用這張」＝不動作（Head Sub 已說明要先點一張）。
    private func useSelected() {
        guard let selectedID, let photo = photos?.first(where: { $0.id == selectedID }) else { return }
        onUse(photo, urls[photo.displayPath])
        dismiss()
    }

    /// 清單一次讀、簽名 URL 一次批次取（不逐張 await）。
    private func load() async {
        loadError = nil
        do {
            let loaded = try await apiClient.listFamilyPhotos(childID: childID)
            let signed = try await apiClient.signedURLs(forStoragePaths: loaded.map(\.displayPath))
            urls = signed
            photos = loaded
        } catch {
            loadError = AppError.map(error)
        }
    }
}
