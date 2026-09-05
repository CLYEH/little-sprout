import SwiftUI

// LS-191：獨立檔案（不是塞進 WelcomeView.swift 本體）——那個檔案加上法務 sheet 的改動就會
// 超過 SwiftLint file_length 上限，同 `WelcomeView+PasswordSignIn.swift`（LS-164）的既有
// 拆檔理由。`presentedLegalDocument` 因此改成非 private（見 WelcomeView.swift 該處註解）。
extension WelcomeView {
    /// 法務／狀態行是一個 38pt 固定高度插槽（進場條件⑥）：`.meta`(13pt) 的法務行與
    /// `.note`(17pt) 的狀態句行高不同，沒有這個插槽 01→01b 切換會把上方按鈕整體推移。用
    /// `minHeight` 而不是 `height`——AX3 下兩者都會換行超過 38pt，此時插槽要能跟著長高，
    /// 不能裁切（spec 明記 AX3「legal wraps to 64pt, no slot」）。
    var legalOrStatusSlot: some View {
        Group {
            // R1 review F1：任一登入方式在跑都要有回饋（原本只有 Apple 有）——Google 面板
            // 關閉、PKCE code exchange 仍在跑的那幾秒，原本會三顆鈕全灰卻零提示，長輩會
            // 誤以為沒反應而改按別顆，造成兩條登入流程並行。
            if let statusMessage = authButtonsState.statusMessage {
                Text(statusMessage)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextPrimary)
            } else {
                // 法務行在一般字級下一行放得下、AX3 放不下（稿面量測 462+33pt vs 345pt 容器
                // 寬）：`ViewThatFits` 先試單行，放不下才落到會自動換行的第二個候選（進場條件⑧，
                // 不照抄 .pen 稿面的固定四段式節點排版，因為那不會自動換行）。
                ViewThatFits(in: .horizontal) {
                    Text(legalAttributedString)
                        .appFont(.meta)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(legalAttributedString)
                        .appFont(.meta)
                }
            }
        }
        .frame(minHeight: 38, alignment: .leading)
    }

    /// LS-191：兩個連結原本指向真的 https URL（跳出系統瀏覽器），現在改用
    /// `LegalDocumentKind.linkURL` 這個自訂 scheme——`Text` 渲染 `AttributedString` 的
    /// `.link` 時，點擊一律先問環境裡的 `OpenURLAction`（見 `legalLinkOpenURLAction`），
    /// 不是真的請系統打開網址。
    var legalAttributedString: AttributedString {
        var intro = AttributedString("登入即表示你同意")
        intro.foregroundColor = .lsTextSecondary

        var terms = AttributedString("《使用條款》")
        terms.foregroundColor = .lsTextPrimary
        terms.underlineStyle = .single
        terms.link = LegalDocumentKind.termsOfService.linkURL

        var and = AttributedString("與")
        and.foregroundColor = .lsTextSecondary

        var privacy = AttributedString("《隱私權政策》")
        privacy.foregroundColor = .lsTextPrimary
        privacy.underlineStyle = .single
        privacy.link = LegalDocumentKind.privacyPolicy.linkURL

        return intro + terms + and + privacy
    }

    /// `legalAttributedString` 的兩個連結點擊後要開 `LegalDocumentSheet`，不是真的要打開
    /// 網址：認得出 `legalsheet://` scheme 就設定 `presentedLegalDocument`（`WelcomeView.body`
    /// 的 `.sheet(item:)` 接住）並回傳 `.handled`；認不出的 URL（理論上不會出現在這個畫面，
    /// 但保留 systemAction 兜底，不吃掉其他潛在連結的預設行為）交回系統。
    var legalLinkOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard let kind = LegalDocumentKind(linkURL: url) else { return .systemAction }
            presentedLegalDocument = kind
            return .handled
        }
    }
}
