import PhotosUI
import SwiftUI

/// `CreateChildView` 頭像欄——拆成獨立檔案（SwiftLint `type_body_length` 逼出來的搬移，
/// 理由同 `MediaUploadService+Duration.swift` 檔頭註解：這裡的成員原本是 `private`，
/// `private` 是以檔案為界，搬到別的檔案就存取不到 `CreateChildView` 的 `@State`，改用
/// 預設（internal）存取層級，範圍仍只在本 module 內）。
extension CreateChildView {
    var avatarField: some View {
        VStack(spacing: AppSpacing.label) {
            PhotosPicker(selection: $pickedAvatarItem, matching: .images) {
                AvatarPrintCard(name: name, pickedImage: pickedAvatarPreview)
                    .frame(maxWidth: .infinity)
                    .overlay { avatarLoadingOverlay }
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            if let avatarLoadErrorMessage {
                Text(avatarLoadErrorMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
        }
    }

    /// R2 M3：載入期間顯示一個進度圈，不讓使用者以為「點了沒反應」——這正是原本的失敗
    /// 情境（iCloud 大圖要等好幾秒、畫面完全沒有載入指示，見 merge-review R1 M3）。
    @ViewBuilder
    var avatarLoadingOverlay: some View {
        if isLoadingAvatar {
            Color.black.opacity(0.25)
            ProgressView().tint(.white)
        }
    }

    /// R2 M2/M3：`.task(id: pickedAvatarItem)`（`body` 裡掛載）呼叫這支——`id` 改變（連續
    /// 選兩張）時 SwiftUI 自動取消前一個 task、畫面消失時也自動取消；載入結果（含降採樣後的
    /// 預覽圖，見 `AvatarPickerLoader`）直接寫進 `@State`，不再靠計算屬性每次 `body` 重新
    /// 解碼一次全尺寸原圖（merge-review R1 M2）。載入失敗落 `avatarLoadErrorMessage` 顯示
    /// 出來，不是原本 `try?` 靜默吞掉、預覽悄悄退回佔位。
    ///
    /// R3 n2：`.task(id:)` 取消舊 task 時，舊 task 不會立刻停在原地——它會繼續往下跑到
    /// 結束才真正停止，跟新 task（新選的那張圖）幾乎同時在跑。若不比對世代，舊 task 會蓋掉
    /// 新 task 剛設成 `true` 的進度圈（連選兩張時第二張還在載入，圈圈卻先消失），非
    /// `CancellationError` 的例外也可能把新 task 已經寫好的預覽圖清掉、留下舊的錯誤文案。
    ///
    /// LS-173：世代守門本體（領號、比對、`CancellationError` 靜默）抽到
    /// `AvatarLoadCoordinator.load(operation:)`（供單元測試覆蓋，見該型別文件註解）——這裡
    /// 只負責把 `.applied`／`.discarded`／`.failed` 三種分類結果套進 `@State`，行為與原本
    /// 直接寫世代比對邏輯時逐位相同。
    func loadPickedAvatar() async {
        guard let pickedAvatarItem else { return }
        isLoadingAvatar = true
        avatarLoadErrorMessage = nil
        let result = await avatarLoadCoordinator.load {
            try await AvatarPickerLoader.load(pickedAvatarItem)
        }
        if result.isCurrent {
            isLoadingAvatar = false
        }
        switch result.outcome {
        case .applied(let data, let previewImage):
            pickedAvatarData = data
            pickedAvatarPreview = previewImage
        case .discarded:
            break
        case .failed(let message):
            pickedAvatarData = nil
            pickedAvatarPreview = nil
            avatarLoadErrorMessage = message
        }
    }
}
