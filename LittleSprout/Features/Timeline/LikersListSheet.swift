import SwiftUI

/// 按讚名單（LS-216 依 LS-177 稿 `GZ3pb`；Handoff Notes `EclPC` 節「按讚名單」`uLBa2`）——
/// 點擊互動列的 `Count Zone`（計數 >0 時）開啟，純資訊性列表：顯示按讚者姓名＋
/// `ProfilePrintChip` 沖印占位頭像（`size: 40`，同 Notes `d5RNKR` 定案 scale），不含任何
/// 動作（不能移除／封鎖）。資料直接 SELECT `reactions` join `profiles`（RLS 隔離即可，
/// 無需新 RPC，見 `TimelineAPIClient.reactors`），不快取——每次開啟重查一次。
///
/// 自畫 grabber＋`.presentationDetents([.medium, .large])`＋隱藏系統拖曳指示——同
/// `ContentActionsSheet` 既有理由（系統 `.presentationDragIndicator` 會被 tap-target gate
/// 誤判成 <44pt 違規）。
struct LikersListSheet: View {
    let kind: FeedKind
    let refId: UUID
    let timelineStore: TimelineStore
    /// 開啟當下互動列已知的計數——開場標題（「N 人按了愛心」）先用這個值，避免查詢完成前
    /// 短暫顯示「0 人」；`reactors` 陣列載入完成後標題改用實際筆數（兩者理論上一致，只有
    /// 極罕見的同時按讚／收回才會有一瞬間落差，不特別處理）。
    let likeCount: Int

    @State private var reactors: [ReactorRow] = []
    @State private var isLoading = true
    @State private var loadError: AppError?

    private var headline: String {
        "\(isLoading ? likeCount : reactors.count) 人按了愛心"
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            Text(headline)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.bottom, AppSpacing.block)
            content
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.bottom, AppSpacing.section)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task { await load() }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if let loadError {
            Text(loadError.userFacingMessage)
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    ForEach(reactors) { reactor in
                        likerRow(reactor)
                    }
                }
            }
        }
    }

    private func likerRow(_ reactor: ReactorRow) -> some View {
        HStack(spacing: AppSpacing.group) {
            ProfilePrintChip(size: 40)
            Text(reactor.displayName)
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
        }
        // 純資訊性列表，無任何動作（票文 scope 3）——不掛 Button／contentShape，只讓
        // VoiceOver 把姓名唸出來即可。
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let familyID = timelineStore.familyID else {
            isLoading = false
            return
        }
        do {
            reactors = try await timelineStore.reactors(kind: kind, refId: refId, familyID: familyID)
            loadError = nil
        } catch {
            loadError = AppError.map(error)
        }
        isLoading = false
    }
}

#if DEBUG
#Preview {
    let store = TimelineStore.preview()
    let refId = UUID()
    return Color.clear.sheet(isPresented: .constant(true)) {
        LikersListSheet(kind: .diary, refId: refId, timelineStore: store, likeCount: 4)
    }
}
#endif
