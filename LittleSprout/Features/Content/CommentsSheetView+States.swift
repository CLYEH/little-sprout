import SwiftUI

/// LS-218：內容區的四種狀態——骨架載入（`MJ-5`，見 Notes `k9WANR`）、空狀態（`TnxXE`）、可重試
/// 錯誤態（`dHSyh` 網路中斷＋其餘未預期錯誤的通用兜底）、LS026 終態（目標已刪／不屬本家庭）。
/// 拆到獨立檔案的理由見 `CommentsSheetView.swift` 檔頭註解。
extension CommentsSheetView {
    /// iPad 卡片的留言清單固定 400（Notes `M3T3g`：「`wY7f8`（iPad）沿用 400（與 iPhone
    /// 同）」，是設計刻意保留的規格值，不是 iPhone 全高 detent 那種依可用空間動態撐滿）；
    /// iPhone 全高 detent 讓清單填滿剩餘空間。
    func mainBody(horizontalPadding: CGFloat, isPadIdiom: Bool) -> some View {
        Group {
            contentArea
                .padding(.horizontal, horizontalPadding)
                .padding(.top, AppSpacing.block)
                .frame(maxHeight: isPadIdiom ? 400 : .infinity)
            Rectangle().fill(Color.lsBorder).frame(height: 1)
                .padding(.horizontal, horizontalPadding).padding(.top, AppSpacing.block)
            footer.padding(.horizontal, horizontalPadding)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        switch store.initialLoadState {
        case .idle, .submitting:
            skeletonList
        case .failure(let error):
            // `targetGoneError` 已經在 `content(horizontalPadding:showsGrabber:)` 攔截過，
            // 這裡只會是網路／其他可重試錯誤。
            retryableErrorState(CommentsErrorPresentation.make(from: error))
        case .success:
            if store.comments.isEmpty {
                emptyState
            } else {
                commentsList
            }
        }
    }

    private var skeletonList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.section) {
            ForEach(0..<3, id: \.self) { _ in skeletonRow }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在載入留言")
    }

    private var skeletonRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.group) {
            RoundedRectangle(cornerRadius: 6).fill(Color.lsSurface2).frame(width: avatarSize, height: avatarSize)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                RoundedRectangle(cornerRadius: 4).fill(Color.lsSurface2).frame(width: 96, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(Color.lsSurface2).frame(maxWidth: .infinity).frame(height: 17)
                RoundedRectangle(cornerRadius: 4).fill(Color.lsSurface2).frame(maxWidth: 220).frame(height: 17)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.group) {
            EmptyPrintView()
            Text("還沒有人留言").appFont(.body).foregroundStyle(Color.lsTextPrimary)
            Text("第一個跟家人說說話吧").appFont(.note).foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func retryableErrorState(_ presentation: CommentsErrorPresentation) -> some View {
        VStack(spacing: AppSpacing.group) {
            Image(systemName: presentation.icon).font(.system(size: 32)).foregroundStyle(Color.lsTextSecondary)
            Text(presentation.title).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            Text(presentation.message)
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button {
                Task { await store.loadInitial() }
            } label: {
                Text("重試")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsAccent)
                    .padding(.vertical, AppSpacing.item)
                    .padding(.horizontal, AppSpacing.item)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier(QAAccessibilityID.commentRetryButton)
        }
        .frame(maxWidth: .infinity)
    }

    /// LS026——`targetGoneError` 非 `nil` 時整張 sheet（含 footer 輸入列）換成這個態：票文
    /// 「無法查看或新增留言」明確表示連新增入口都不該留著，不是只換清單區塊。
    func targetGoneState(for error: AppError, horizontalPadding: CGFloat) -> some View {
        let presentation = CommentsErrorPresentation.targetGone
        return VStack(spacing: AppSpacing.group) {
            Spacer(minLength: 0)
            Image(systemName: presentation.icon).font(.system(size: 32)).foregroundStyle(Color.lsTextSecondary)
            Text(presentation.title).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            Text(presentation.message)
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button {
                dismiss()
            } label: {
                Text("關閉")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            }
            .accessibilityIdentifier(QAAccessibilityID.commentCloseButton)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, AppSpacing.block)
        .frame(maxHeight: .infinity)
    }
}

/// 空狀態的空白沖印品（`TnxXE` `K1yE6j`）——同 `ProfilePrintChip` 的白邊＋左上／右下角托視覺
/// 語言，但內頁完全透明（`Empty Page` 節點 `HwcGv` fill 為 `#00000000`：沒有照片，也沒有人像
/// icon）。merge-review R1 m6：淺色外觀下 `$print-paper`／`$surface` 同色（皆
/// `#FBEBEC`），若只靠內頁透明會讓整張卡片在淺色模式視覺消失——離線讀 `.pen` `K1yE6j` 節點
/// 補回設計原本就有、先前遺漏的兩層：外框 `$paper-edge` 描邊＋`$paper-shadow` 陰影（稿面
/// Notes `EclPC` MJ-5「換成空白沖印品（白邊＋左上/右下角托＋`$print-paper` 空內頁）」明講
/// 是靠這道「白邊」可見，不是內頁本身），以及內頁 `HwcGv` 的 `$border` 描邊（把透明內頁的
/// 邊界畫出來，而不是無邊框的純色塊）——三者皆既有 `Color.lsPaperEdge`／`Color.lsPaperShadow`／
/// `Color.lsBorder` token，未新增或修改任何 token 值。稿面卡片為直角方形（無 cornerRadius
/// 欄位，同 `ppXvK`「Print」等其餘沖印品 frame），故移除先前誤加的 8pt 圓角裁切。
private struct EmptyPrintView: View {
    private let outerSize: CGFloat = 120
    private let innerSize: CGFloat = 104
    private let cornerSize: CGFloat = 18
    private let cornerOut: CGFloat = 5

    var body: some View {
        Color.lsPrintPaper
            .frame(width: outerSize, height: outerSize)
            .overlay(Rectangle().strokeBorder(Color.lsPaperEdge, lineWidth: 1))
            .shadow(color: Color.lsPaperShadow, radius: 6, x: 0, y: 3)
            .overlay(
                Rectangle()
                    .strokeBorder(Color.lsBorder, lineWidth: 1)
                    .frame(width: innerSize, height: innerSize)
            )
            .overlay(corner(.topLeading, alignment: .topLeading, out: -cornerOut))
            .overlay(corner(.bottomTrailing, alignment: .bottomTrailing, out: cornerOut))
            .accessibilityHidden(true)
    }

    private func corner(_ corner: PhotoCorner, alignment: Alignment, out: CGFloat) -> some View {
        let shape = PhotoCornerShape(corner: corner)
        return ZStack {
            shape.fill(Color.lsPhotoCorner)
            shape.foldEdge(in: CGRect(x: 0, y: 0, width: cornerSize, height: cornerSize))
                .stroke(Color.lsCornerFold, lineWidth: 1)
        }
        .frame(width: cornerSize, height: cornerSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .offset(x: out, y: out)
    }
}
