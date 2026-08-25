import Foundation

/// 設計語言 v3.3 的間距與尺寸 token（Tokens 板「④ 間距節奏」「⑤ 尺寸與圓角」）。
///
/// 這些是版面間距／內距值，不隨 Dynamic Type 縮放——控制項的高度改由「內容高度 + 這些
/// padding」自然推導（見 Handoff Notes「點擊目標」段），字級變大時控制項跟著長高，不需要
/// 另外把間距本身也做成 `@ScaledMetric`（那是給 icon／字級用的，見 `Typography.swift`）。
enum AppSpacing {
    static let tight: CGFloat = 6
    static let label: CGFloat = 8
    static let group: CGFloat = 12
    static let item: CGFloat = 16
    static let block: CGFloat = 24
    static let section: CGFloat = 44

    static let controlPaddingNav: CGFloat = 9
    static let controlPaddingTap: CGFloat = 9.5
    static let controlPaddingMedium: CGFloat = 15.5
    static let controlPaddingCTA: CGFloat = 17.5

    static let insetCard: CGFloat = 20
    static let screenPad: CGFloat = 24
    static let screenPadLarge: CGFloat = 40
    static let cornerOut: CGFloat = 5

    static let radiusMedium: CGFloat = 14
    static let radiusLarge: CGFloat = 18

    static let printEdge: CGFloat = 8
    static let printEdgeBottom: CGFloat = 8
}
