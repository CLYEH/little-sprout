import Foundation

/// 02 畫面的欄位格式檢查（送出前的客戶端檢查，攔截「還沒打完」這種明顯不完整的輸入；
/// 後端／Supabase 仍是格式驗證的最終權威，這裡只負責即時回饋，不取代後端檢查）。
enum EmailFormat {
    static func isValid(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let localPart = parts[0]
        let domainPart = parts[1]
        guard !localPart.isEmpty else { return false }

        let domainLabels = domainPart.split(separator: ".", omittingEmptySubsequences: false)
        guard domainLabels.count >= 2 else { return false }
        return domainLabels.allSatisfy { !$0.isEmpty } && (domainLabels.last?.count ?? 0) >= 2
    }
}
