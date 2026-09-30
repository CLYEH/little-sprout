import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// LS-404（`design/littlesprout.pen` LS-402 板 `HOKKA`／`Ej5G5`／`JNDUz`／`Hzv2U`）：設定頁最上方的
/// 「正在新增照片」上傳佇列入口——取代 LS-397 暫定的「內容與安全」末列。iPhone 在 Content 第一段
/// （Header Row 之下、「個人」段之上），iPad 在 Sidebar 標題「設定」之下、Nav List 之上；獨立一張
/// Card（clip、18 圓角、1pt `$border`，即 `SettingsCard`），不加段標題。
///
/// 純邏輯（四態、文案、停留期間狀態機）在 `UploadQueueEntryPresentation.swift`；這裡是 View 接線：
/// `UploadQueueEntryModel` 持有目前顯示的態與 sheet／儲存空間導覽旗標，`UploadQueueEntryLifecycle`
/// 掛在 `SettingsView` 最外層（sheet 不能掛在會隱藏的列上，否則列隱藏時 sheet 跟著被收掉）。

extension UploadQueueEntryCounts {
    @MainActor
    init(store: UploadQueueStore?) {
        guard let store else {
            self = .zero
            return
        }
        // LS-410：標記移除中的失敗項（sheet 開著、還沒 `commitRemovals`）仍算失敗——入口列在 sheet 關閉（情境邊界）
        // 才重新快照，sheet 開著時它背後的列不因標記而變態（否則 `liveChanged` 會在 sheet 後面先原地換成「全部完成」）。
        let failedEntries = store.entries.values.count { if case .failed = $0.state { true } else { false } }
        self.init(
            waiting: store.waitingCount, uploading: store.uploadingCount, failed: failedEntries,
            completed: store.completedCount
        )
    }
}

/// 入口列的畫面狀態：目前顯示的態（`UploadQueueEntryState`）＋量到的各態列高＋sheet／導覽旗標。
@MainActor
@Observable
final class UploadQueueEntryModel {
    private(set) var state = UploadQueueEntryState()
    var showsSheet = false
    /// sheet 內「查看儲存空間」的出路（同 LS-397 暫定入口）。
    var showsStorage = false
    @ObservationIgnored private var heights: [UploadQueueEntryPhase: CGFloat] = [:]
    @ObservationIgnored private var latest = UploadQueueEntryCounts.zero

    /// 情境邊界（設定頁 onAppear／sheet 關閉／App 回前景）：重新評估態與行數。
    func contextBoundary(_ counts: UploadQueueEntryCounts) {
        latest = counts
        state.contextBoundary(counts)
    }

    /// 停留期間佇列變化：列高相同才原地換態（見 `UploadQueueEntryState.liveChanged`）。
    func liveChanged(_ counts: UploadQueueEntryCounts) {
        latest = counts
        state.liveChanged(counts) { heights[$0] }
    }

    /// 列高量測回報（目前顯示態＋待換入態的探針）——量到之後重新判斷一次原地換態。
    func heightsChanged(_ measured: [UploadQueueEntryPhase: CGFloat]) {
        heights = measured
        state.liveChanged(latest) { heights[$0] }
    }
}

private struct UploadQueueEntryHeightKey: PreferenceKey {
    static let defaultValue: [UploadQueueEntryPhase: CGFloat] = [:]

    typealias Heights = [UploadQueueEntryPhase: CGFloat]

    static func reduce(value: inout Heights, nextValue: () -> Heights) {
        value.merge(nextValue()) { $1 }
    }
}

/// 入口列本體（Card＋`SettingsRowView` 實例）。目前態為 `nil` 時什麼都不畫（連 Card 都沒有）。
struct UploadQueueEntryCard: View {
    let store: UploadQueueStore
    let model: UploadQueueEntryModel

    var body: some View {
        if let phase = model.state.phase {
            card(phase)
        }
    }

    private func card(_ phase: UploadQueueEntryPhase) -> some View {
        let counts = UploadQueueEntryCounts(store: store)
        // 佇列現況要換入的態≠目前顯示的態時，在背景量一份它的列高，供狀態機判斷「列高相同才原地換態」。
        let probe = counts.phase.flatMap { $0 == phase ? nil : $0 }
        return SettingsCard {
            Button {
                model.showsSheet = true
            } label: {
                row(phase, counts, leading: AnyView(UploadQueueEntryThumbnail(store: store, phase: phase)))
                    .background { heightReader(phase) }
                    .background(alignment: .top) {
                        if let probe {
                            row(probe, counts, leading: AnyView(Color.clear.frame(width: 44, height: 44)))
                                .fixedSize(horizontal: false, vertical: true)
                                .background { heightReader(probe) }
                                .opacity(0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .accessibilityIdentifier(QAAccessibilityID.settingsUploadQueueRow)
            .accessibilityLabel(UploadQueueEntryCopy.accessibilityLabel(phase, counts))
        }
        .onPreferenceChange(UploadQueueEntryHeightKey.self) { measured in
            MainActor.assumeIsolated { model.heightsChanged(measured) }
        }
    }

    /// 只剩失敗態的 Label 整句 `$danger`（`isDestructive` 只染 Label／icon，chevron 與副標維持 `$text-secondary`，
    /// 正是稿面 `g6OqC` 的配色）。
    private func row(_ phase: UploadQueueEntryPhase, _ counts: UploadQueueEntryCounts, leading: AnyView) -> some View {
        SettingsRowView(
            icon: nil, label: UploadQueueEntryCopy.label(phase, counts),
            value: UploadQueueEntryCopy.value(phase, counts), isDestructive: phase == .onlyFailed,
            leading: leading, failureLine: UploadQueueEntryCopy.failureLine(phase, counts)
        )
        // `Button` 的 label 預設把多行文字置中；稿面（`JNDUz` AX3 折行）是靠左，只在這列覆寫，不動其餘設定列。
        .multilineTextAlignment(.leading)
    }

    private func heightReader(_ phase: UploadQueueEntryPhase) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: UploadQueueEntryHeightKey.self, value: [phase: proxy.size.height])
        }
    }
}

/// 44×44 佇列縮圖（Notes `OT5n9`：圓角 2、clip、零白邊零角托——還在路上的照片不是沖印品）。縮圖取自佇列
/// （與 sheet 同源）：進行中＝正在上傳那張、只剩失敗＝第一張失敗的、全部完成＝最後完成那張。
///
/// 記憶體縮圖不在（app 重啟後還原的項目，或終局後被 `releaseThumbnails` 釋放）時，由佇列落盤的原檔
/// 重新產生 44pt@3x（Notes `kI2bt` ④）；連原檔也不在（已終局）才退回色塊，同 `UploadQueueRowView` 的
/// nil-thumbnail 佔位。
private struct UploadQueueEntryThumbnail: View {
    let store: UploadQueueStore
    let phase: UploadQueueEntryPhase
    @State private var regenerated: (id: UUID, image: UIImage)?

    var body: some View {
        let entryID = store.entryThumbnailID(for: phase)
        let image = entryID.flatMap { store.thumbnail(for: $0) }
            ?? (regenerated?.id == entryID ? regenerated?.image : nil)
        return Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.lsSurface2
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
        .task(id: entryID) { await regenerate(entryID) }
    }

    private func regenerate(_ entryID: UUID?) async {
        guard let entryID, store.thumbnail(for: entryID) == nil, regenerated?.id != entryID,
              let payload = store.entries[entryID]?.payload else { return }
        if let image = await UploadQueueEntryThumbnailLoader.load(payload) {
            regenerated = (entryID, image)
        }
    }
}

/// 落盤原檔 → 44pt@3x（132px）縮圖：照片用 `CGImageSource` 降採樣（不把整張原圖解碼進記憶體），影片取首幀。
enum UploadQueueEntryThumbnailLoader {
    static let maxPixelSize: CGFloat = 132

    static func load(_ payload: PendingUpload.Kind) async -> UIImage? {
        await Task.detached(priority: .utility) { decode(payload) }.value
    }

    private static func decode(_ payload: PendingUpload.Kind) -> UIImage? {
        switch payload {
        case .photo(let data, _):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
        case .video(let fileURL, _):
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init(cgImage:))
        }
    }
}

extension UploadQueueStore {
    /// 入口列縮圖取自哪一筆（Notes `OT5n9`）：進行中（含＋失敗）＝正在上傳那張（沒有上傳中就取排最前的等候）、
    /// 只剩失敗＝第一張失敗的、全部完成＝最後完成那張；找不到時（停留期間顯示的態落後於現況）退回其餘
    /// 任何一筆，避免縮圖無故變色塊。
    func entryThumbnailID(for phase: UploadQueueEntryPhase) -> UUID? {
        func kind(_ match: @escaping (UploadItemState) -> Bool, last: Bool = false) -> Candidate {
            Candidate(match: match, last: last)
        }
        let uploading = kind { if case .uploading = $0 { true } else { false } }
        let waiting = kind { if case .waiting = $0 { true } else { false } }
        let failed = kind { if case .failed = $0 { true } else { false } }
        let completed = kind({ if case .completed = $0 { true } else { false } }, last: true)
        let priorities: [Candidate] = switch phase {
        case .inProgress, .inProgressWithFailure: [uploading, waiting, failed, completed]
        case .onlyFailed: [failed, uploading, waiting, completed]
        case .allDone: [completed, failed, uploading, waiting]
        }
        for candidate in priorities {
            let matches = order.filter { entries[$0].map { candidate.match($0.state) } ?? false }
            if let id = candidate.last ? matches.last : matches.first { return id }
        }
        return nil
    }

    private struct Candidate {
        let match: (UploadItemState) -> Bool
        let last: Bool
    }
}

/// 掛在 `SettingsView` 最外層：三個情境邊界（onAppear／sheet 關閉／回前景）＋停留期間的數字更新，
/// 以及 sheet 與「查看儲存空間」導覽（不能掛在會隱藏的列上）。
struct UploadQueueEntryLifecycle: ViewModifier {
    @Bindable var model: UploadQueueEntryModel
    let albumsStore: AlbumsStore
    let familyStore: FamilyStore

    func body(content: Content) -> some View {
        let store = albumsStore.sharedUploadQueueStoreInstance
        let counts = UploadQueueEntryCounts(store: store)
        return content
            .onAppear { model.contextBoundary(counts) }
            // App 回前景：`UploadQueueStore.appDidBecomeActive()` 每次結束都遞增（含沒有項目要重送時），
            // 在它把可重試失敗翻回等候「之後」才評估，不受 `RootView` 與這裡兩個 scenePhase 觀察者
            // 先後順序影響。
            .onChange(of: store?.resume.foregroundEpoch) { model.contextBoundary(UploadQueueEntryCounts(store: store)) }
            .onChange(of: counts) { _, newCounts in model.liveChanged(newCounts) }
            .sheet(isPresented: $model.showsSheet, onDismiss: {
                // LS-410（merge-review i3）：sheet 內標記的移除在這裡真的提交，且**先於** `contextBoundary`——入口列
                // 拿提交後的佇列重新快照；放在 sheet 內容的 onDisappear 與這個 onDismiss 的先後 SwiftUI 不保證。
                albumsStore.sharedUploadQueueStoreInstance?.commitRemovals()
                model.contextBoundary(UploadQueueEntryCounts(store: albumsStore.sharedUploadQueueStoreInstance))
            }, content: {
                if let store {
                    UploadQueueSheetView(store: store, onViewStorage: {
                        model.showsSheet = false
                        model.showsStorage = true
                    })
                }
            })
            .navigationDestination(isPresented: $model.showsStorage) {
                StorageUsageView(familyStore: familyStore)
            }
    }
}
