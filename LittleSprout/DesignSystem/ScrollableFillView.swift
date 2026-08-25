import SwiftUI

/// 畫面內容在一般字級下用 `Spacer` 撐開（對應 .pen `justifyContent: space_between`），AX
/// 字級把內容撐爆一屏高度時改成可捲動，不裁切——外層必包 ScrollView（LS-46 R11 進場條件；
/// 原始 Design gate 交接註記也點名這點）。
///
/// 做法：內容先取螢幕可視高度當 `minHeight`，一般字級下用滿；AX 字級時內容自然長高過
/// `minHeight`，`ScrollView` 接手捲動。
struct ScrollableFillView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: proxy.size.height)
            }
        }
    }
}
