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
    /// `defer`／`catch` 才真正結束，跟新 task（新選的那張圖）幾乎同時在跑。若不比對世代，
    /// 舊 task 的 `defer { isLoadingAvatar = false }` 會蓋掉新 task 剛設成 `true` 的進度圈
    /// （連選兩張時第二張還在載入，圈圈卻先消失），非 `CancellationError` 的例外也可能把
    /// 新 task 已經寫好的預覽圖清掉、留下舊的錯誤文案。做法：一進函式就領一個世代號，寫任何
    /// 會被畫面讀到的狀態前都先確認自己仍是最新世代；`CancellationError` 本來就什麼都不寫，
    /// 不需要世代判斷。
    func loadPickedAvatar() async {
        guard let pickedAvatarItem else { return }
        avatarLoadGeneration += 1
        let generation = avatarLoadGeneration
        isLoadingAvatar = true
        avatarLoadErrorMessage = nil
        defer {
            if generation == avatarLoadGeneration {
                isLoadingAvatar = false
            }
        }
        do {
            let loaded = try await AvatarPickerLoader.load(pickedAvatarItem)
            guard generation == avatarLoadGeneration else { return }
            pickedAvatarData = loaded.data
            pickedAvatarPreview = loaded.previewImage
        } catch is CancellationError {
            // 被下一次選取取消——狀態交給後面那個 task 寫，這裡什麼都不做（一律靜默）。
        } catch {
            guard generation == avatarLoadGeneration else { return }
            pickedAvatarData = nil
            pickedAvatarPreview = nil
            avatarLoadErrorMessage = "這張照片沒辦法使用，請換一張試試。"
        }
    }
}
