import SwiftUI

/// LS-120／LS-136：`cmp/Tab Bar` 全字級純 icon——四顆分頁圖示的浮動膠囊，取代
/// `SectionTabView` 原本 `.tabItem` 畫出的系統文字＋圖示分頁列（系統列已用
/// `.toolbar(.hidden, for: .tabBar)` 隱藏，見 `RootView.swift`）。
///
/// 選中態＝一張紙：`$surface` 圓角方形＋1.5pt `$control-line` 描邊＋落影，icon 由
/// `$text-secondary` 26pt 放大到 `$text-primary` 32pt；未選中維持裸 icon、不畫任何框
/// （稿面上未選中 Indicator 的 fill/stroke 與外層膠囊同色、shadow 歸零，視覺上等於沒有
/// 框——這裡直接不畫，效果相同，見 Notes `LuHbv`「LS-120 · 規則」段）。
///
/// AX3（`.accessibility3` 起，同 `ChildFilterLayout.forcesDropdown` 既有的兩態切換慣例，
/// 不是連續縮放曲線）：icon 40／48、膠囊高 88——`.pen` 只定案了「預設」與「AX3」兩個具名
/// 斷點的精確像素值（Notes `LuHbv`「LS-120 R2 · 尺寸 token」段），中間字級級距沿用預設值，
/// 不是每一階都內插；這與既有 `AppIconToken`／`@ScaledMetric` 曲線（值由系統決定、不保證
/// 命中設計稿字面數字）不同，所以這裡不套用那組 token，改用本檔自己的斷點常數。
struct SectionTabBar: View {
    @Binding var selection: AppSection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAX3: Bool { dynamicTypeSize >= .accessibility3 }
    private var capsuleHeight: CGFloat { isAX3 ? 88 : 64 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.allCases) { section in
                tabCell(section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(AppSpacing.tight)
        .frame(height: capsuleHeight)
        .background(Color.lsSurface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.lsControlLine, lineWidth: 1))
        .shadow(color: Color.lsPaperShadow, radius: 5, x: 0, y: 2)
    }

    private func tabCell(_ section: AppSection) -> some View {
        let isSelected = section == selection
        let iconSize = iconSize(selected: isSelected)
        return Button {
            selection = section
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .fill(Color.lsSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                                .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
                        )
                        .shadow(color: Color.lsPaperShadow, radius: 1.5, x: 0, y: 1)
                        .frame(width: iconSize + AppSpacing.tight * 2, height: iconSize + AppSpacing.tight * 2)
                }
                Image(systemName: section.systemImage)
                    .font(.system(size: iconSize))
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(isSelected ? Color.lsTextPrimary : Color.lsTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Notes `LuHbv`「LS-120 R2 · a11y」段(c)：icon 葉節點裝飾用，資訊已在 cell 層級的
        // accessibilityLabel 承載；這裡對整個 cell（非葉節點）補長按大字標籤，是拿掉可見
        // tab 文字後的「加強」路徑，不是唯一路徑——唯一路徑是 entry-conditions.md ⑬
        // 「tab-root 目的地畫面 display 標題＝該 tab 名稱」。
        .accessibilityShowsLargeContentViewer {
            Label(section.title, systemImage: section.systemImage)
        }
    }

    private func iconSize(selected: Bool) -> CGFloat {
        switch (selected, isAX3) {
        case (false, false): 26
        case (true, false): 32
        case (false, true): 40
        case (true, true): 48
        }
    }
}

#Preview("Default") {
    VStack {
        Spacer()
        SectionTabBar(selection: .constant(.timeline))
            .padding(.horizontal, 16)
    }
    .background(Color.lsBackground)
}

#Preview("AX3") {
    VStack {
        Spacer()
        SectionTabBar(selection: .constant(.children))
            .padding(.horizontal, 16)
    }
    .background(Color.lsBackground)
    .dynamicTypeSize(.accessibility3)
}
