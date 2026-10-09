#if DEBUG
import SwiftUI

/// LS-381：飲食圖鑑 04 記錄詳情家族的 harness host——同 `TapTargetGateHarness+Food.swift` 的拆檔先例，
/// 供 `FoodRecordDetailUITests`（權限三態按鈕集合、日期章、角托、對稿截圖）與 `TapTargetGateTests` 用。
///
/// 示範資料沿 Notes `UsJkk`（小安，出生 2025-04-20）：
/// - `.foodRecordDetail`（04 `B8krzV`）：吐司麵包 2026/6/8、喜歡、有照片，作者＝登入者（媽媽，owner）→ 只有「編輯」。
/// - `.foodRecordDetailNoPhoto`（04b `gIo3O`）：南瓜 2025/11/18、喜歡、沒有照片，作者＝登入者 → 空白沖印品可點＋「編輯」。
/// - `.foodRecordDetailOwner`（04c `Z8zWzZ`）：吐司麵包，作者＝爸爸、登入者＝媽媽（owner）→ 只有「刪除」。
/// - `.foodRecordDetailViewer`：吐司麵包，登入者＝阿嬤（viewer）→ 沒有任何動作。
///
/// 深色：launch argument `-LSFoodRecordDetailDark YES`（`UserDefaults`），不另開 case。
/// 四支都用 `NavigationStack(path:)` 帶非空初始路徑、根畫面標題「飲食圖鑑」——真實用法從圖鑑推入，系統返回鍵才是
/// 稿面 Nav Back「飲食圖鑑」（同 `foodBookStack`）。
extension TapTargetGateHarness {
    enum FoodRecordDetailFixture {
        case author, noPhoto, owner, viewer
    }

    static let foodRecordDetailDarkKey = "LSFoodRecordDetailDark"
    /// `.foodRecordDetailViewer`：改看沒有照片的南瓜（04d 非作者看無照片記錄）。
    static let foodRecordDetailNoPhotoKey = "LSFoodRecordDetailNoPhoto"
    /// `.foodRecordDetail`：照片簽名網址拿不到（04e 照片沒有載入）。
    static let foodRecordDetailPhotoFailedKey = "LSFoodRecordDetailPhotoFailed"

    /// `hostView(for:)` 的 switch 已貼著 SwiftLint `type_body_length` 上限，四個 case 併成一行、在這裡對照 fixture。
    @MainActor
    static func foodRecordDetailHost(for screen: TapTargetGateScreenName) -> some View {
        let fixture: FoodRecordDetailFixture = switch screen {
        case .foodRecordDetailNoPhoto: .noPhoto
        case .foodRecordDetailOwner: .owner
        case .foodRecordDetailViewer: .viewer
        default: .author
        }
        let isDark = UserDefaults.standard.bool(forKey: foodRecordDetailDarkKey)
        return NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationTitle("飲食圖鑑")
                .navigationDestination(for: Bool.self) { _ in FoodRecordDetailSample.view(fixture) }
        }
        .preferredColorScheme(isDark ? .dark : nil)
    }
}

private enum FoodRecordDetailSample {
    static let mom = UUID()
    static let dad = UUID()
    static let grandma = UUID()
    static let child = Child(
        id: UUID(), name: "小安", birthday: BirthdayFormat.date(fromWireString: "2025-04-20")!,
        avatarURL: nil, deletedAt: nil, createdAt: Date()
    )

    /// 記錄固定成 `static let`：destination 閉包每次重繪都會重跑，若每次新建 `UUID()`，`FoodRecordDetailView`
    /// 的 `.task(id: record.id)` 會不斷重建 store。
    static let bread = PreviewFoodCatalog.items.first { $0.id == "bread" }!
    static let pumpkin = PreviewFoodCatalog.items.first { $0.id == "pumpkin" }!
    static let breadByMom = record(foodID: "bread", day: "2026-06-08", author: mom, hasPhoto: true, note: breadNote)
    static let breadByDad = record(foodID: "bread", day: "2026-06-08", author: dad, hasPhoto: true, note: breadNote)
    static let pumpkinByMom = record(
        foodID: "pumpkin", day: "2025-11-18", author: mom, hasPhoto: false, note: "一口接一口，把整碗吃光了。"
    )
    private static let breadNote = "自己抓著吃，吃得滿臉都是麵包屑。"

    @MainActor
    static func view(_ fixture: TapTargetGateHarness.FoodRecordDetailFixture) -> FoodRecordDetailView {
        let viewerSeesNoPhoto = UserDefaults.standard.bool(forKey: TapTargetGateHarness.foodRecordDetailNoPhotoKey)
        let (item, record): (FoodCatalogItem, ChildFoodRecord) = switch fixture {
        case .viewer where viewerSeesNoPhoto: (pumpkin, pumpkinByMom)
        case .author, .viewer: (bread, breadByMom)
        case .noPhoto: (pumpkin, pumpkinByMom)
        case .owner: (bread, breadByDad)
        }
        let isViewer = fixture == .viewer
        return FoodRecordDetailView(
            child: child, item: item, record: record, apiClient: PreviewFoodAPIClient(records: [record]),
            currentUserID: isViewer ? grandma : mom, isFamilyOwner: !isViewer, canRecord: !isViewer,
            detailAPIClient: PreviewFoodRecordDetailAPIClient(
                names: [mom: "媽媽", dad: "爸爸", grandma: "阿嬤"],
                photoAvailable: !UserDefaults.standard.bool(forKey: TapTargetGateHarness.foodRecordDetailPhotoFailedKey)
            )
        )
    }

    private static func record(
        foodID: String, day: String, author: UUID, hasPhoto: Bool, note: String
    ) -> ChildFoodRecord {
        let date = BirthdayFormat.date(fromWireString: day)!
        return ChildFoodRecord(
            id: UUID(), familyID: UUID(), childID: child.id, foodID: foodID, authorID: author, firstTriedOn: date,
            mediaID: hasPhoto ? UUID() : nil, note: note, reaction: "liked", createdAt: date, updatedAt: date
        )
    }
}
#endif
