#if DEBUG
import SwiftUI
import UIKit

/// LS-404：設定頁上傳佇列入口列（`UploadQueueEntryCard`）的 harness——`UploadQueueEntryUITests`／
/// `UploadQueueEntryIPadTests` 的淺深 × xSmall／預設／AX3＋iPad 截圖矩陣與停留期間行為斷言。
///
/// 真的 `SettingsView`（含 `UploadQueueEntryLifecycle`），`albumsStore.sharedUploadQueueStoreInstance`
/// 換成種好狀態的 `UploadQueueStore`（`LS_UPLOAD_QUEUE_ENTRY_FIXTURE` 選）：
/// - `none`：全部已完成、沒有未完成項＝列不顯示（間距回歸）。
/// - `progress`：30 張已完成 3（2 上傳中、25 等候）＝稿面「進行中」。
/// - `progressFailure`：同上但其中 1 張失敗＝「進行中＋失敗」。
/// - `onlyFailed`：29 張完成、1 張失敗＝「只剩失敗」。
/// - `allDone`：進行中，畫面出現 4 秒後全部完成＝停留期間「原地換成全部完成」。
/// - `stayFailure`：進行中，4 秒後一張失敗、3.5 秒後另一張完成＝停留期間只更新數字、不增行。
/// - `progressThenFailedOnly`：還有 9 張，4 秒後剩下的全部完成、最後一張失敗（9→1）＝「進行中→只剩失敗」，
///   用來量 iPad／中間字級列高不同時不原地換態。
/// - LS-410（sheet 移除失敗項）：`sheetProgressFailures`＝3 張失敗（LS002／連線中斷／伺服器忙碌）＋進行中，開 sheet 是
///   稿面 16c；`sheetOnlyFailed`＝同樣 3 張失敗、沒有進行中，開 sheet 是 16d。標記移除後的 16f／16g 由 UITest 點「移除」得到。
/// `LS_UPLOAD_QUEUE_ENTRY_SCHEME=dark` 釘深色；`LS_UPLOAD_QUEUE_ENTRY_LAYOUT=regular` 走 iPad 兩欄版面
/// （否則 compact，並在底部掛真正的 `SectionTabBar` 以驗「Tab Bar 不遮」）。
extension TapTargetGateHarness {
    @MainActor
    static var settingsUploadQueueEntryHost: some View {
        let environment = ProcessInfo.processInfo.environment
        return SettingsUploadQueueEntryHost(
            fixture: environment["LS_UPLOAD_QUEUE_ENTRY_FIXTURE"] ?? "progress",
            isRegular: environment["LS_UPLOAD_QUEUE_ENTRY_LAYOUT"] == "regular"
        )
        .preferredColorScheme(environment["LS_UPLOAD_QUEUE_ENTRY_SCHEME"] == "dark" ? .dark : .light)
    }
}

/// 永遠不回來的上傳服務——種成「上傳中」的項目不會自己完成，狀態只由劇本改。
private final class HangingMediaUploadService: MediaUploadService, @unchecked Sendable {
    func uploadPhoto( // swiftlint:disable:this function_parameter_count
        familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize, takenAt: Date?, mediaID: UUID?
    ) async throws -> UUID {
        try await Task.sleep(for: .seconds(3600))
        return mediaID ?? UUID()
    }

    func uploadVideo( // swiftlint:disable:this function_parameter_count
        familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize, takenAt: Date?, mediaID: UUID?
    ) async throws -> UUID {
        try await Task.sleep(for: .seconds(3600))
        return mediaID ?? UUID()
    }

    func softDeleteMedia(mediaIDs: [UUID]) async throws {}
}

private struct SettingsUploadQueueEntryHost: View {
    let fixture: String
    let isRegular: Bool
    @State private var albumsStore: AlbumsStore

    init(fixture: String, isRegular: Bool) {
        self.fixture = fixture
        self.isRegular = isRegular
        let albums = AlbumsStore.preview()
        albums.sharedUploadQueueStoreInstance = Self.seededStore(fixture)
        _albumsStore = State(initialValue: albums)
    }

    var body: some View {
        NavigationStack {
            SettingsView(
                authStore: .preview(),
                familyStore: TapTargetGateHarness.settingsFamilyStore(withFamily: Family(
                    id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
                )),
                childrenStore: .preview(), accountAPIClient: PreviewAccountAPIClient(),
                timelineStore: .preview(), albumsStore: albumsStore,
                eulaStore: .preview(shouldPresent: false), resumer: .preview(),
                safetyAPIClient: PreviewSafetyAPIClient(), pushNotificationStore: .preview()
            )
        }
        .environment(\.horizontalSizeClass, isRegular ? .regular : .compact)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isRegular {
                SectionTabBar(selection: .constant(.settings)).padding(.horizontal, 16)
            }
        }
        .task { await runScript() }
    }

    // MARK: - 種子

    private static func seededStore(_ fixture: String) -> UploadQueueStore {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: HangingMediaUploadService())
        let now = Date()
        var seeds: [UploadQueueStore.PreviewSeed] = []
        func add(_ state: UploadItemState, color: UIColor) {
            let upload = PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: swatch(color),
                pixelSize: PixelSize(width: 4, height: 3)
            )
            seeds.append(.init(upload, enqueuedAt: now.addingTimeInterval(TimeInterval(-seeds.count)), state: state))
        }
        switch fixture {
        case "none":
            (0..<3).forEach { _ in add(.completed, color: .systemTeal) }
        case "onlyFailed":
            (0..<29).forEach { _ in add(.completed, color: .systemTeal) }
            add(.failed(.network), color: .systemOrange)
        case "sheetOnlyFailed":
            (0..<4).forEach { _ in add(.completed, color: .systemTeal) }
            add(.failed(.quota), color: .systemOrange)
            add(.failed(.network), color: .systemRed)
            add(.failed(.server), color: .systemBrown)
        case "sheetProgressFailures":
            (0..<3).forEach { _ in add(.completed, color: .systemTeal) }
            add(.failed(.quota), color: .systemOrange)
            add(.failed(.network), color: .systemRed)
            add(.failed(.server), color: .systemBrown)
            add(.uploading(progress: nil), color: .systemPink)
            add(.waiting, color: .systemIndigo)
        default:
            (0..<3).forEach { _ in add(.completed, color: .systemTeal) }
            add(.uploading(progress: nil), color: .systemPink)
            add(.uploading(progress: nil), color: .systemPurple)
            // `progressThenFailedOnly` 只剩個位數張：劇本把數字 9→1，位數不變，列高改變只能來自「換態」，
            // 不會混進「數字位數變少讓文字少折一行」（那是數字更新，不是換態）。
            let waiting = fixture == "progressThenFailedOnly" ? 7 : (fixture == "progressFailure" ? 24 : 25)
            (0..<waiting).forEach { _ in add(.waiting, color: .systemIndigo) }
            if fixture == "progressFailure" { add(.failed(.network), color: .systemOrange) }
        }
        store.seedForPreview(seeds)
        return store
    }

    private static func swatch(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 132, height: 132)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 132, height: 132))
        }
    }

    // MARK: - 劇本（停留期間的佇列變化）

    /// 劇本起跑延遲：要夠久，UITest 才來得及先讀到初始態（冷啟動慢的機器上 2.5 秒曾被劇本搶先）。
    private static let scriptDelay = 4.0

    private func runScript() async {
        guard let store = albumsStore.sharedUploadQueueStoreInstance else { return }
        switch fixture {
        case "allDone":
            try? await Task.sleep(for: .seconds(Self.scriptDelay))
            for id in store.order where !isCompleted(store, id) { store.finish(id, state: .completed) }
        case "stayFailure":
            try? await Task.sleep(for: .seconds(Self.scriptDelay))
            if let id = store.order.first(where: { isUploading(store, $0) }) {
                store.finish(id, state: .failed(.network))
            }
            try? await Task.sleep(for: .seconds(1))
            if let id = store.order.first(where: { isWaiting(store, $0) }) { store.finish(id, state: .completed) }
        case "progressThenFailedOnly":
            try? await Task.sleep(for: .seconds(Self.scriptDelay))
            let open = store.order.filter { !isCompleted(store, $0) }
            for id in open.dropLast() { store.finish(id, state: .completed) }
            if let id = open.last { store.finish(id, state: .failed(.network)) }
        default:
            break
        }
    }

    private func isCompleted(_ store: UploadQueueStore, _ id: UUID) -> Bool {
        if case .completed? = store.entries[id]?.state { true } else { false }
    }

    private func isUploading(_ store: UploadQueueStore, _ id: UUID) -> Bool {
        if case .uploading? = store.entries[id]?.state { true } else { false }
    }

    private func isWaiting(_ store: UploadQueueStore, _ id: UUID) -> Bool {
        if case .waiting? = store.entries[id]?.state { true } else { false }
    }
}
#endif
