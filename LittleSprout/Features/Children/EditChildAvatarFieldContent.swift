import SwiftUI

/// `EditChildView`（LS-113 / 09b）頭像欄內容：縮寫圓／照片（LS-169：`pickedImage` 非 nil
/// 時本地預覽優先，否則走 `avatarURL`，同 `ChildAvatarView` 的優先序）＋相機 Edit Badge＋
/// 「換張照片」文字。
///
/// 獨立成一支 `View`-conforming struct，不是 `EditChildView` 上的計算屬性——`PhotosPicker`
/// 的 `label` 閉包參數不繼承外層呼叫端的 `@MainActor` 隔離（實測 Swift 6 嚴格並行檢查），
/// 直接在該閉包本體呼叫 `appFont`／`appIconFrame` 這兩個 `@MainActor` 隔離的自訂 View
/// extension 方法會編譯失敗；獨立 View struct 的 `body` 本身就是 `@MainActor`（`View`
/// 協定要求），閉包只需要呼叫它的 initializer（非隔離、純建構值），交給 SwiftUI 之後才真正
/// 求值 `body`。詳見 `EditChildView.avatarField` 文件註解。
struct EditChildAvatarFieldContent: View {
    let name: String
    var avatarURL: URL?
    var pickedImage: UIImage?

    var body: some View {
        VStack(spacing: AppSpacing.label) {
            ZStack(alignment: .bottomTrailing) {
                avatarPreview
                Circle()
                    .fill(Color.lsSurface)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Color.lsControlLine, lineWidth: 1.5))
                    .overlay(
                        Image(systemName: "camera")
                            .appIconFrame(.small)
                            .foregroundStyle(Color.lsTextPrimary)
                    )
            }
            Text("換張照片")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name)的大頭貼，點一下可以換照片")
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let pickedImage {
            Image(uiImage: pickedImage)
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipShape(Circle())
        } else {
            ChildAvatarView(name: name, size: 88, avatarURL: avatarURL)
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 24) {
        EditChildAvatarFieldContent(name: "陳小安")
        EditChildAvatarFieldContent(name: "")
    }
    .padding()
}
#endif
